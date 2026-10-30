/* TEST ONLY: on-demand pixels from the actual SDL renderer before Present.
 * No OS screenshot capture, Android transport, private API, or production changes.
 *
 * DROIDBRIDGE_AUDIO_PLAYER_CAPTURE_ROOT: explicit per-client owned directory.
 * Request: atomically write capture-request containing a positive decimal ID.
 * Reply: atomic capture-ack.json with the matching ID; when passed=true,
 * frame.bmp was atomically replaced first. Increasing IDs prevent stale reuse.
 * Nothing is captured unless a new request exists. Children lose injection.
 */
#include <SDL3/SDL.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int root_fd = -1;
static char capture_root[PATH_MAX];
static unsigned long long last_request;

__attribute__((constructor)) static void capture_setup(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    const char *root = getenv("DROIDBRIDGE_AUDIO_PLAYER_CAPTURE_ROOT");
    if (!root || root[0] != '/' || strlen(root) >= sizeof(capture_root)) return;
    int descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat metadata;
    if (descriptor < 0) return;
    if (fstat(descriptor, &metadata) != 0 || !S_ISDIR(metadata.st_mode) ||
        metadata.st_uid != getuid() || (metadata.st_mode & 0022) != 0) {
        close(descriptor); return;
    }
    memcpy(capture_root, root, strlen(root) + 1);
    root_fd = descriptor;
}
__attribute__((destructor)) static void capture_finish(void) {
    if (root_fd >= 0) close(root_fd);
}
static unsigned long long requested_id(void) {
    if (root_fd < 0) return 0;
    int descriptor = openat(root_fd, "capture-request", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) return 0;
    struct stat metadata;
    char text[65];
    ssize_t length = -1;
    if (fstat(descriptor, &metadata) == 0 && S_ISREG(metadata.st_mode) &&
        metadata.st_uid == getuid() && metadata.st_size > 0 && metadata.st_size <= 64)
        length = read(descriptor, text, 64);
    close(descriptor);
    if (length <= 0) return 0;
    text[length] = 0;
    char *first = text;
    while (isspace((unsigned char)*first)) first++;
    if (!isdigit((unsigned char)*first)) return 0;
    errno = 0;
    char *end;
    unsigned long long identifier = strtoull(first, &end, 10);
    if (errno || end == first) return 0;
    while (isspace((unsigned char)*end)) end++;
    if (*end || !identifier || identifier <= last_request) return 0;
    return identifier;
}
static void json_string(FILE *file, const char *value) {
    fputc('"', file);
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; p++) {
        if (*p == '"' || *p == '\\') { fputc('\\', file); fputc(*p, file); }
        else if (*p < 32) fprintf(file, "\\u%04x", *p);
        else fputc(*p, file);
    }
    fputc('"', file);
}
static void acknowledge(unsigned long long identifier, bool success, int width,
                        int height, int output_width, int output_height, bool main_thread, const char *renderer_name,
                        const char *error) {
    char temporary[96];
    snprintf(temporary, sizeof(temporary), ".capture-ack-%d-%llu.tmp", getpid(), identifier);
    int descriptor = openat(root_fd, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) return;
    FILE *file = fdopen(descriptor, "w");
    if (!file) { close(descriptor); unlinkat(root_fd, temporary, 0); return; }
    fprintf(file, "{\"id\":%llu,\"pid\":%d,\"passed\":%s,\"width\":%d,\"height\":%d,\"output_width\":%d,\"output_height\":%d,\"main_thread\":%s,\"physical_screen_verified\":false,\"capture_method\":\"SDL_RenderReadPixels-before-SDL_RenderPresent\",\"renderer\":",
            identifier, getpid(), success ? "true" : "false", width, height, output_width, output_height, main_thread ? "true" : "false");
    json_string(file, renderer_name);
    fputs(",\"error\":", file); json_string(file, error); fputs("}\n", file);
    bool complete = fflush(file) == 0;
    if (fclose(file) != 0) complete = false;
    if (complete) renameat(root_fd, temporary, root_fd, "capture-ack.json");
    else unlinkat(root_fd, temporary, 0);
}
static bool capture_before_present(SDL_Renderer *renderer) {
    unsigned long long identifier = requested_id();
    if (identifier) {
        last_request = identifier;
        bool success = false, main_thread = SDL_IsMainThread();
        int width = 0, height = 0, output_width = 0, output_height = 0;
        char error[512] = "", temporary[96] = "", path[PATH_MAX];
        const char *renderer_name = SDL_GetRendererName(renderer);
        if (!main_thread) snprintf(error, sizeof(error), "Capture refused outside SDL main thread");
        else if (!SDL_GetRenderOutputSize(renderer, &output_width, &output_height))
            snprintf(error, sizeof(error), "Renderer output dimensions: %.440s", SDL_GetError());
        else if (!SDL_GetCurrentRenderOutputSize(renderer, &width, &height))
            snprintf(error, sizeof(error), "Output dimensions: %.450s", SDL_GetError());
        else if (width <= 0 || height <= 0 || (uint64_t)width * (uint64_t)height > 16777216)
            snprintf(error, sizeof(error), "Capture dimensions exceed test limit");
        else {
            SDL_Surface *surface = SDL_RenderReadPixels(renderer, NULL);
            if (!surface) snprintf(error, sizeof(error), "RenderReadPixels: %.450s", SDL_GetError());
            else {
                width = surface->w; height = surface->h;
                snprintf(temporary, sizeof(temporary), ".frame-%d-%llu.bmp", getpid(), identifier);
                int descriptor = openat(root_fd, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
                if (descriptor < 0) snprintf(error, sizeof(error), "Cannot reserve capture temporary: %s", strerror(errno));
                else {
                    close(descriptor);
                    int count = snprintf(path, sizeof(path), "%s/%s", capture_root, temporary);
                    if (count < 0 || (size_t)count >= sizeof(path)) snprintf(error, sizeof(error), "Capture path too long");
                    else if (!SDL_SaveBMP(surface, path)) snprintf(error, sizeof(error), "SaveBMP: %.450s", SDL_GetError());
                    else if (renameat(root_fd, temporary, root_fd, "frame.bmp") != 0)
                        snprintf(error, sizeof(error), "Cannot publish captured frame: %s", strerror(errno));
                    else success = true;
                }
                if (!success && temporary[0]) unlinkat(root_fd, temporary, 0);
                SDL_DestroySurface(surface);
            }
        }
        acknowledge(identifier, success, width, height, output_width, output_height, main_thread, renderer_name, error);
    }
    /* Direct original-symbol reference avoids the dlsym/interpose recursion
     * previously found in test audio observers. Present always occurs once. */
    return SDL_RenderPresent(renderer);
}
__attribute__((used)) static struct { const void *replacement, *original; }
interpose_present __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&capture_before_present, (const void *)&SDL_RenderPresent
};

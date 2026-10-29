/* TEST ONLY: public SDL event-queue injection in the exact bundled client.
 * This does not claim OS focus delivery while the host desktop is locked.
 * Every window/video API executes inside scrcpy's SDL main event thread.
 */
#include <SDL3/SDL.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Children such as adb do not link SDL. Restrict the injected image to the
 * explicitly launched client; never pass it into its subprocesses. */
__attribute__((constructor)) static void restrict_to_this_process(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
}

static unsigned stage;
static Uint64 window_seen;
static SDL_WindowID target;
static const char *word;
static bool push(SDL_Event *event) {
    bool success = SDL_PushEvent(event);
    fprintf(stderr,"{\"test\":\"SDL_PushEvent\",\"type\":%u,\"window\":%u,\"success\":%s}\n",event->type,target,success?"true":"false");
    return success;
}
static void click(SDL_Window *window,float frame_y) {
    int width=0,height=0; SDL_GetWindowSize(window,&width,&height);
    for (unsigned down=1;;down=0) {
        SDL_Event event; SDL_zero(event);
        event.type=down?SDL_EVENT_MOUSE_BUTTON_DOWN:SDL_EVENT_MOUSE_BUTTON_UP;
        event.button.timestamp=SDL_GetTicksNS(); event.button.windowID=target;
        event.button.which=0; event.button.button=SDL_BUTTON_LEFT;
        event.button.down=down; event.button.clicks=1;
        event.button.x=(float)width*0.5f; event.button.y=(float)height*frame_y/1080.f;
        push(&event); if (!down) break;
    }
}
static void maybe_inject(void) {
    if (stage>=5) return;
    if (!word) { word=getenv("DROIDBRIDGE_SDL_WORD"); if (!word || strlen(word)>64) { stage=5; return; } }
    SDL_Window *window=NULL;
    if (target) window=SDL_GetWindowFromID(target);
    else {
        int count=0; SDL_Window **windows=SDL_GetWindows(&count);
        if (count>0) { window=windows[0]; target=SDL_GetWindowID(window); }
        SDL_free(windows);
        if (window) {
            window_seen=SDL_GetTicks();
            SDL_SetModState(SDL_KMOD_NONE); /* Controlled fixture, no held shortcuts. */
            int width=0,height=0; SDL_GetWindowSize(window,&width,&height);
            fprintf(stderr,"{\"test\":\"SDL_window_ready\",\"version\":%d,\"main_thread\":%s,\"window\":%u,\"width\":%d,\"height\":%d}\n",SDL_GetVersion(),SDL_IsMainThread()?"true":"false",target,width,height);
        }
    }
    if (!window) return;
    const char *trigger=getenv("DROIDBRIDGE_SDL_TRIGGER");
    static bool triggered;
    if (!triggered) { if (!trigger || access(trigger,F_OK)!=0) return; triggered=true; window_seen=SDL_GetTicks(); }
    Uint64 elapsed=SDL_GetTicks()-window_seen;
    SDL_SetModState(SDL_KMOD_NONE); /* Controlled fixture, re-clear host focus modifier drift after idle. */
    if (stage==0 && elapsed>=2500) { click(window,225.f); stage=1; }
    else if (stage==1 && elapsed>=3500) { click(window,295.f); stage=2; }
    else if (stage==2 && elapsed>=5500) {
        fprintf(stderr,"{\"test\":\"text_modifiers\",\"value\":%u}\n",(unsigned)SDL_GetModState());
        SDL_Event event; SDL_zero(event); event.type=SDL_EVENT_TEXT_INPUT;
        event.text.timestamp=SDL_GetTicksNS(); event.text.windowID=target; event.text.text=word;
        push(&event); stage=3;
    } else if (stage==3 && elapsed>=6500) {
        /* Default mixed keyboard mode sends ASCII letters as raw key events.
         * The leading-digit text commit above follows its public text path;
         * this extra character independently exercises its default key path. */
        for (unsigned down=1;;down=0) {
            SDL_Event event; SDL_zero(event); event.type=down?SDL_EVENT_KEY_DOWN:SDL_EVENT_KEY_UP;
            event.key.timestamp=SDL_GetTicksNS(); event.key.windowID=target;
            event.key.which=0; event.key.scancode=SDL_SCANCODE_K; event.key.key=SDLK_K;
            event.key.down=down; event.key.mod=SDL_KMOD_NONE;
            push(&event); if (!down) break;
        }
        stage=4;
    } else if (stage==4 && elapsed>=7000) {
        fprintf(stderr,"{\"test\":\"SDL_input_complete\",\"word\":\"%s\",\"window\":%u}\n",word,target); stage=5;
    }
}
static bool verify_wait_event(SDL_Event *event) {
    maybe_inject();
    while (!SDL_WaitEventTimeout(event,50)) maybe_inject();
    maybe_inject();
    return true;
}
/* The interpose applies to the client, while this image's reference calls the
 * original public SDL implementation. No private scrcpy function is patched. */
__attribute__((used)) static struct { const void *replacement; const void *original; } interpose_wait
__attribute__((section("__DATA,__interpose"))) = {(const void *)&verify_wait_event,(const void *)&SDL_WaitEvent};

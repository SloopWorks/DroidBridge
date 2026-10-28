/* TEST ONLY: expose the client's real decoder/Texture log while it is live.
 * No rendering, input, transport, or lifecycle function is intercepted. */
#include <stdio.h>
__attribute__((constructor)) static void qa_unbuffered_logs(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

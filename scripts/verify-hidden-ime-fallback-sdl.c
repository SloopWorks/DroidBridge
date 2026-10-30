#include <SDL3/SDL.h>
#include <stdio.h>
/* TEST ONLY. Keep the unchanged client's public event queue responsive when
 * Cocoa activation/wakeup delivery is suppressed by the locked host. */
static bool wait_event(SDL_Event *event) {
    while (!SDL_WaitEventTimeout(event,50)) {}
    static unsigned observations;
    if (observations<40 && (event->type==SDL_EVENT_MOUSE_BUTTON_DOWN || event->type==SDL_EVENT_MOUSE_BUTTON_UP || event->type==SDL_EVENT_TEXT_INPUT || event->type==SDL_EVENT_KEY_DOWN || event->type==SDL_EVENT_KEY_UP)) {
        ++observations;
        fprintf(stderr,"{\"test\":\"public_SDL_event_consumed\",\"type\":%u,\"main_thread\":%s}\n",event->type,SDL_IsMainThread()?"true":"false");
    }
    return true;
}
__attribute__((used)) static struct {const void *replacement;const void *original;} interpose
__attribute__((section("__DATA,__interpose")))={(const void *)&wait_event,(const void *)&SDL_WaitEvent};

#include <SDL3/SDL.h>
#include <stdio.h>
int main(void) {
    if (!SDL_Init(SDL_INIT_EVENTS)) return 1;
    SDL_Event input={0},output={0}; input.type=SDL_EVENT_USER;
    if (!SDL_PushEvent(&input) || !SDL_WaitEvent(&output)) return 2;
    printf("actual SDL %d original WaitEvent returned type=%u\n",SDL_GetVersion(),output.type);
    SDL_Quit(); return output.type==SDL_EVENT_USER?0:3;
}

#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
static char root[4096];
static void path(char *out,const char *name){snprintf(out,4096,"%s/%s",root,name);}
static void request(unsigned long long identifier){char file[4096];path(file,"capture-request");FILE *f=fopen(file,"w");assert(f);fprintf(f,"%llu\n",identifier);assert(fclose(f)==0);}
static void check_color(Uint8 red,Uint8 green,Uint8 blue){char file[4096];path(file,"frame.bmp");SDL_Surface *surface=SDL_LoadBMP(file);assert(surface);Uint8 r,g,b,a;assert(SDL_ReadSurfacePixel(surface,8,6,&r,&g,&b,&a));assert(r==red&&g==green&&b==blue&&a==255);SDL_DestroySurface(surface);}
int main(int argc,char **argv){
 assert(argc==2);assert(strlen(argv[1])<sizeof(root));strcpy(root,argv[1]);assert(SDL_Init(0));
 SDL_Surface *surface=SDL_CreateSurface(16,12,SDL_PIXELFORMAT_RGBA32);assert(surface);
 SDL_Renderer *renderer=SDL_CreateSoftwareRenderer(surface);assert(renderer);
 char file[4096];path(file,"capture-ack.json");assert(access(file,F_OK)!=0);
 assert(SDL_SetRenderDrawColor(renderer,255,0,0,255));assert(SDL_RenderClear(renderer));assert(SDL_RenderPresent(renderer));assert(access(file,F_OK)!=0); // no request
 request(1);assert(SDL_RenderClear(renderer));assert(SDL_RenderPresent(renderer));assert(access(file,F_OK)==0);check_color(255,0,0);
 assert(SDL_SetRenderDrawColor(renderer,0,0,255,255));assert(SDL_RenderClear(renderer));assert(SDL_RenderPresent(renderer));check_color(255,0,0); // duplicate id never captures
 request(2);assert(SDL_RenderClear(renderer));assert(SDL_RenderPresent(renderer));check_color(0,0,255);
 request(1);assert(SDL_SetRenderDrawColor(renderer,0,255,0,255));assert(SDL_RenderClear(renderer));assert(SDL_RenderPresent(renderer));check_color(0,0,255); // lower stale id refused
 SDL_DestroyRenderer(renderer);SDL_DestroySurface(surface);SDL_Quit();puts("PASS: no unsolicited capture; fresh red/blue before-present pixels; duplicate/stale requests refused");return 0;
}

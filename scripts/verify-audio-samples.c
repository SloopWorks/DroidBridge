/* Test-only successful SDL PCM observer. A bounded SPSC ring carries mono
 * synthetic-test samples off the real-time callback. The callback never waits
 * for a lock or writes files. Only aggregate tone/RMS metrics are persisted;
 * this is queued PCM evidence, not physical speaker audibility. */
#include <SDL3/SDL_audio.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define CAPACITY 96000
static float ring[CAPACITY];
static _Atomic unsigned long head=0,tail=0,dropped=0;
static _Atomic int running=1,rate=0,channels=0;
static pthread_t worker;
static int worker_started=0;
static char *output_path;
static double block[4800];

static double magnitude(double hz,int sample_rate) {
 double coefficient=2*cos(2*M_PI*hz/sample_rate),a=0,b=0;
 for(int i=0;i<4800;i++){double value=block[i]+coefficient*a-b;b=a;a=value;}
 return 2*sqrt(fmax(0,a*a+b*b-coefficient*a*b))/4800;
}
static void *consume(void *unused) {
 (void)unused;
 int fd=open(output_path,O_CREAT|O_APPEND|O_WRONLY|O_NOFOLLOW,0600);
 FILE *file=fd>=0?fdopen(fd,"a"):NULL;
 if(!file){if(fd>=0)close(fd);return NULL;}
 int count=0;unsigned long frames=0;
 while(atomic_load(&running)||atomic_load(&tail)<atomic_load(&head)){
  unsigned long position=atomic_load_explicit(&tail,memory_order_relaxed);
  unsigned long end=atomic_load_explicit(&head,memory_order_acquire);
  if(position==end){struct timespec delay={0,10000000};nanosleep(&delay,NULL);continue;}
  while(position<end){
   block[count++]=ring[position%CAPACITY];position++;frames++;
   if(count==4800){
    double sum=0,peak=0;
    for(int i=0;i<count;i++){sum+=block[i]*block[i];peak=fmax(peak,fabs(block[i]));}
    int actual_rate=atomic_load(&rate);
    fprintf(file,"{\"pid\":%d,\"accepted_frames\":%lu,\"rate\":%d,\"channels\":%d,\"rms\":%.8f,\"peak\":%.8f,\"tone997\":%.8f,\"tone1499\":%.8f,\"dropped_frames\":%lu}\n",getpid(),frames,actual_rate,atomic_load(&channels),sqrt(sum/count),peak,magnitude(997,actual_rate),magnitude(1499,actual_rate),atomic_load(&dropped));
    fflush(file);count=0;
   }
  }
  atomic_store_explicit(&tail,position,memory_order_release);
 }
 fclose(file);return NULL;
}
static void finish(void){
 atomic_store(&running,0);
 if(worker_started)pthread_join(worker,NULL);
 free(output_path);
}
__attribute__((constructor)) static void begin_observer(void){
 unsetenv("DYLD_INSERT_LIBRARIES");unsetenv("DYLD_LIBRARY_PATH");
 const char *path=getenv("DROIDBRIDGE_AUDIO_PROBE_OUTPUT");
 if(path){output_path=strdup(path);worker_started=pthread_create(&worker,NULL,consume,NULL)==0;atexit(finish);}
}
static bool observe_put(SDL_AudioStream *stream,const void *buffer,int length){
 /* References inside this interposer stay bound to the original function.
  * dlsym(RTLD_NEXT) reapplied interposition and caused a preserved fixture fault. */
 bool accepted=SDL_PutAudioStreamData(stream,buffer,length);
 if(!accepted||!worker_started)return accepted;
 int sample_rate=atomic_load(&rate),channel_count=atomic_load(&channels);
 if(!sample_rate){
  SDL_AudioSpec input={0},destination={0};
  if(!SDL_GetAudioStreamFormat(stream,&input,&destination)||input.format!=SDL_AUDIO_F32LE||input.channels<1||input.freq<=0)return accepted;
  sample_rate=input.freq;channel_count=input.channels;
  atomic_store(&channels,channel_count);atomic_store(&rate,sample_rate);
 }
 const float *data=buffer;
 unsigned long samples=(unsigned long)(length/(int)sizeof(float)/channel_count);
 unsigned long position=atomic_load_explicit(&head,memory_order_relaxed);
 unsigned long available=CAPACITY-(position-atomic_load_explicit(&tail,memory_order_acquire));
 unsigned long copy=samples<available?samples:available;
 for(unsigned long i=0;i<copy;i++)ring[(position+i)%CAPACITY]=data[i*channel_count];
 atomic_store_explicit(&head,position+copy,memory_order_release);
 if(copy<samples)atomic_fetch_add(&dropped,samples-copy);
 return accepted;
}
__attribute__((used)) static struct {const void *replacement,*original;}
interpose_put __attribute__((section("__DATA,__interpose")))={observe_put,SDL_PutAudioStreamData};

#include "CDesktopUI.h"
#ifdef _WIN32
#include <windows.h>
#include <mmsystem.h>
#pragma comment(lib,"winmm.lib")
#include <atomic>
#include <cmath>
static std::atomic<float> wave_level(-1.0f);
float castor_wave_level(void){return wave_level.load();}
int castor_play_pcm(const int16_t *samples,size_t count,int channels,int sampleRate,int (*cancelled)(void*),void *context) {
    if(!samples||count<1||count>32*1024*1024||channels<1||channels>8||count%channels||sampleRate<8000||sampleRate>192000)return -1;
    WAVEFORMATEX format={};format.wFormatTag=WAVE_FORMAT_PCM;format.nChannels=(WORD)channels;
    format.nSamplesPerSec=sampleRate;format.wBitsPerSample=16;format.nBlockAlign=(WORD)(channels*2);format.nAvgBytesPerSec=sampleRate*format.nBlockAlign;
    HWAVEOUT output=nullptr;WAVEHDR header={};int result=-1;
    if(waveOutOpen(&output,WAVE_MAPPER,&format,0,0,CALLBACK_NULL)!=MMSYSERR_NOERROR)return -1;
    header.lpData=(LPSTR)samples;header.dwBufferLength=(DWORD)(count*2);
    if(waveOutPrepareHeader(output,&header,sizeof(header))==MMSYSERR_NOERROR) {
        if(waveOutWrite(output,&header,sizeof(header))==MMSYSERR_NOERROR) {
            result=1;wave_level.store(0);
            while(!(header.dwFlags&WHDR_DONE)) {
                if(cancelled&&cancelled(context)){waveOutReset(output);result=0;break;}
                MMTIME position={};position.wType=TIME_SAMPLES;
                if(waveOutGetPosition(output,&position,sizeof(position))==MMSYSERR_NOERROR && position.wType==TIME_SAMPLES) {
                    size_t start=(size_t)position.u.sample*(size_t)channels;
                    if(start<count) {
                        size_t length=(size_t)sampleRate*(size_t)channels/20;
                        if(length>count-start)length=count-start;
                        double sum=0;for(size_t i=0;i<length;++i){double v=samples[start+i]/32768.0;sum+=v*v;}
                        float level=length?(float)fmin(1.0,sqrt(sum/length)*4.5):0;
                        wave_level.store(level);
                    }
                }
                Sleep(10);
            }
        }
        waveOutReset(output);
        while(waveOutUnprepareHeader(output,&header,sizeof(header))==WAVERR_STILLPLAYING)Sleep(5);
    }
    waveOutClose(output);wave_level.store(-1);return result;
}
#else
float castor_wave_level(void){return -1;}
int castor_play_pcm(const int16_t *samples,size_t count,int channels,int sampleRate,int (*cancelled)(void*),void *context){return -1;}
#endif

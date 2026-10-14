#include "CDesktopUI.h"
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <thread>

/* Local RMS only. Samples are never stored or sent to a model/service. */
struct AudioWorker {
    std::atomic<bool> enabled{false};std::atomic<float> level{0};std::atomic<int> status{0};
    AudioWorker() {std::thread([this]{run();}).detach();}
    void run() {
        HRESULT initialized=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
        if (FAILED(initialized)) {status=-2;return;}
        for (;;) {
            if (!enabled.load()) {level=0;status=0;Sleep(50);continue;}
            IMMDeviceEnumerator *enumerator=nullptr;IMMDevice *device=nullptr;
            IAudioClient *client=nullptr;IAudioCaptureClient *capture=nullptr;WAVEFORMATEX *format=nullptr;
            HRESULT error=CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_INPROC_SERVER,__uuidof(IMMDeviceEnumerator),(void**)&enumerator);
            if (SUCCEEDED(error)) error=enumerator->GetDefaultAudioEndpoint(eCapture,eCommunications,&device);
            if (SUCCEEDED(error)) error=device->Activate(__uuidof(IAudioClient),CLSCTX_INPROC_SERVER,nullptr,(void**)&client);
            if (SUCCEEDED(error)) error=client->GetMixFormat(&format);
            int encoding=0;
            if (SUCCEEDED(error)) {
                encoding=format->wFormatTag;
                if (encoding==WAVE_FORMAT_EXTENSIBLE && format->cbSize>=22) encoding=(int)((WAVEFORMATEXTENSIBLE*)format)->SubFormat.Data1;
                if (!format->nChannels || format->nChannels>32 ||
                    !((encoding==WAVE_FORMAT_IEEE_FLOAT && format->wBitsPerSample==32) || (encoding==WAVE_FORMAT_PCM && (format->wBitsPerSample==16 || format->wBitsPerSample==24 || format->wBitsPerSample==32)))) error=E_NOTIMPL;
            }
            if (SUCCEEDED(error)) error=client->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_NOPERSIST,1'000'000,0,format,nullptr);
            if (SUCCEEDED(error)) error=client->GetService(__uuidof(IAudioCaptureClient),(void**)&capture);
            if (SUCCEEDED(error)) error=client->Start();
            if (SUCCEEDED(error)) {
                status=1;double smoothed=0;
                while (enabled.load()) {
                    UINT32 frames=0;error=capture->GetNextPacketSize(&frames);if (FAILED(error)) break;
                    while (frames>0 && enabled.load()) {
                        BYTE *bytes=nullptr;DWORD flags=0;UINT32 count=0;
                        error=capture->GetBuffer(&bytes,&count,&flags,nullptr,nullptr);if (FAILED(error)) break;
                        double sum=0;uint64_t samples=(uint64_t)count*format->nChannels;
                        int size=format->wBitsPerSample/8;
                        if (!(flags&AUDCLNT_BUFFERFLAGS_SILENT) && bytes && format->nBlockAlign>=format->nChannels*size) {
                            for (UINT32 frame=0;frame<count;++frame) for (unsigned channel=0;channel<format->nChannels;++channel) {
                                const BYTE *sample=bytes+(size_t)frame*format->nBlockAlign+channel*size;double value=0;
                                if (encoding==WAVE_FORMAT_IEEE_FLOAT) {float f;memcpy(&f,sample,4);value=std::isfinite(f) ? f:0;}
                                else if (size==2) {int16_t v;memcpy(&v,sample,2);value=(double)v/32767;}
                                else if (size==4) {int32_t v;memcpy(&v,sample,4);value=(double)v/2147483647;}
                                else {int32_t v=(int32_t)sample[0]|((int32_t)sample[1]<<8)|((int32_t)sample[2]<<16);if (v&0x800000) v|=(int32_t)0xff000000;value=(double)v/8388607;}
                                sum+=value*value;
                            }
                        }
                        capture->ReleaseBuffer(count);
                        double raw=samples ? std::fmin(1.0,std::sqrt(sum/samples)*(encoding==WAVE_FORMAT_IEEE_FLOAT ? 4.5:5.5)):0;
                        smoothed=smoothed*0.72+raw*0.28;level=(float)smoothed;
                        error=capture->GetNextPacketSize(&frames);if (FAILED(error)) break;
                    }
                    if (FAILED(error)) break;
                    if (frames==0) {smoothed*=0.92;level=(float)smoothed;Sleep(20);}
                }
                client->Stop();
            }
            if (capture) capture->Release();if (format) CoTaskMemFree(format);if (client) client->Release();
            if (device) device->Release();if (enumerator) enumerator->Release();level=0;
            if (FAILED(error)) {
                status=error==E_ACCESSDENIED ? -1:-2;
                // An explicit off/on retries after the user changes privacy/device settings.
                while (enabled.load()) Sleep(50);
            }
        }
    }
};
static AudioWorker *audioWorker=nullptr;
void castor_microphone_enable(int enabled) {
    if (!audioWorker) audioWorker=new AudioWorker();
    audioWorker->enabled=enabled!=0;
}
int castor_microphone_level(float *level) {
    if (!audioWorker) {*level=0;return 0;}
    *level=audioWorker->level.load();return audioWorker->status.load();
}
#else
void castor_microphone_enable(int enabled) {(void)enabled;}
int castor_microphone_level(float *level) {*level=0;return 0;}
#endif

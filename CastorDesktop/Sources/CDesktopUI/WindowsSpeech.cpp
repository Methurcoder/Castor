#include "CDesktopUI.h"
#ifdef _WIN32
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <sapi.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Built-in SAPI adapters. No registry edits, helper process or model upload.
static WCHAR *speech_wide(const char *text) {
    int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,NULL,0);
    if(n<1||n>65536)return nullptr;
    WCHAR *wide=(WCHAR*)malloc((size_t)n*sizeof(WCHAR));
    if(wide&&!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,wide,n)){free(wide);return nullptr;}
    return wide;
}
static int speech_tokens(const WCHAR *categoryId,char *output,size_t capacity) {
    // The UI thread is already single-threaded for WebView2; SAPI works there too.
    HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);if(FAILED(apartment)&&apartment!=RPC_E_CHANGED_MODE)return -1;
    ISpObjectTokenCategory *category=nullptr;IEnumSpObjectTokens *tokens=nullptr;
    HRESULT hr=CoCreateInstance(__uuidof(SpObjectTokenCategory),nullptr,CLSCTX_INPROC_SERVER,
        __uuidof(ISpObjectTokenCategory),(void**)&category);
    if(SUCCEEDED(hr))hr=category->SetId(categoryId,FALSE);
    if(SUCCEEDED(hr))hr=category->EnumTokens(nullptr,nullptr,&tokens);
    size_t used=0;if(capacity)output[0]=0;
    if(SUCCEEDED(hr)) {
        ISpObjectToken *token=nullptr;ULONG fetched=0;
        while(tokens->Next(1,&token,&fetched)==S_OK&&fetched) {
            WCHAR *name=nullptr,*id=nullptr;
            HRESULT item=token->GetStringValue(nullptr,&name);
            if(SUCCEEDED(item))item=token->GetId(&id);
            if(SUCCEEDED(item)) {
                int a=WideCharToMultiByte(CP_UTF8,0,name,-1,nullptr,0,nullptr,nullptr);
                int b=WideCharToMultiByte(CP_UTF8,0,id,-1,nullptr,0,nullptr,nullptr);
                if(a<1||b<1||used+(size_t)a+(size_t)b+3>capacity){hr=E_OUTOFMEMORY;}
                else {
                    if(used)output[used++]='\n';
                    WideCharToMultiByte(CP_UTF8,0,name,-1,output+used,a,nullptr,nullptr);used+=(size_t)a-1;
                    output[used++]='\t';WideCharToMultiByte(CP_UTF8,0,id,-1,output+used,b,nullptr,nullptr);used+=(size_t)b-1;output[used]=0;
                }
            }
            CoTaskMemFree(name);CoTaskMemFree(id);token->Release();token=nullptr;
            if(FAILED(hr))break;
        }
    }
    if(tokens)tokens->Release();if(category)category->Release();if(SUCCEEDED(apartment))CoUninitialize();return SUCCEEDED(hr)?1:-1;
}
int castor_system_voices(char *output,size_t capacity){return speech_tokens(SPCAT_VOICES,output,capacity);}
int castor_system_recognizers(char *output,size_t capacity){return speech_tokens(SPCAT_RECOGNIZERS,output,capacity);}
int castor_system_speak(const char *text,const char *tokenId,int (*cancelled)(void*),void *context) {
    WCHAR *words=speech_wide(text),*id=speech_wide(tokenId);if(!words||!id){free(words);free(id);return -1;}
    HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);if(FAILED(apartment)&&apartment!=RPC_E_CHANGED_MODE){free(words);free(id);return -1;}
    ISpVoice *voice=nullptr;ISpObjectToken *token=nullptr;
    HRESULT hr=CoCreateInstance(__uuidof(SpVoice),nullptr,CLSCTX_INPROC_SERVER,__uuidof(ISpVoice),(void**)&voice);
    if(SUCCEEDED(hr)&&*id) {
        hr=CoCreateInstance(__uuidof(SpObjectToken),nullptr,CLSCTX_INPROC_SERVER,__uuidof(ISpObjectToken),(void**)&token);
        if(SUCCEEDED(hr))hr=token->SetId(nullptr,id,FALSE);
        if(SUCCEEDED(hr))hr=voice->SetVoice(token);
    }
    // SPF_IS_NOT_XML makes model/user text plain speech, never markup commands.
    if(SUCCEEDED(hr))hr=voice->Speak(words,SPF_ASYNC|SPF_IS_NOT_XML,nullptr);
    int result=1;
    while(SUCCEEDED(hr)) {
        if(cancelled&&cancelled(context)){voice->Speak(nullptr,SPF_PURGEBEFORESPEAK,nullptr);result=0;break;}
        hr=voice->WaitUntilDone(100);if(hr==S_OK)break;
    }
    if(FAILED(hr))result=-1;
    if(token)token->Release();if(voice)voice->Release();if(SUCCEEDED(apartment))CoUninitialize();free(words);free(id);return result;
}
int castor_system_recognize_diagnostic(char *output,size_t capacity,char *diagnostic,size_t diagnosticCapacity,int (*cancelled)(void*),void *context) {
    if(capacity<1)return -1;output[0]=0;
    const char *stage="com"; const char *ending="error";
    int events=0,hypotheses=0,sounds=0,result=-1;
    unsigned long engineLanguage=0;
    HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    HRESULT hr=apartment==RPC_E_CHANGED_MODE?S_OK:apartment;
    ISpRecognizer *recognizer=nullptr;ISpRecoContext *reco=nullptr;ISpRecoGrammar *grammar=nullptr;
    if(SUCCEEDED(hr)) {stage="recognizer";hr=CoCreateInstance(__uuidof(SpSharedRecognizer),nullptr,CLSCTX_ALL,__uuidof(ISpRecognizer),(void**)&recognizer);}
    if(SUCCEEDED(hr)) {
        ISpObjectToken *token=nullptr;ISpDataKey *attributes=nullptr;WCHAR *language=nullptr;
        if(SUCCEEDED(recognizer->GetRecognizer(&token))&&token&&
           SUCCEEDED(token->OpenKey(L"Attributes",&attributes))&&attributes&&
           SUCCEEDED(attributes->GetStringValue(L"Language",&language))&&language)
            engineLanguage=wcstoul(language,nullptr,16);
        CoTaskMemFree(language);if(attributes)attributes->Release();if(token)token->Release();
    }
    if(SUCCEEDED(hr)){stage="context";hr=recognizer->CreateRecoContext(&reco);}
    if(SUCCEEDED(hr)){stage="notify";hr=reco->SetNotifyWin32Event();}
    if(SUCCEEDED(hr)) {
        ULONGLONG interest=SPFEI(SPEI_RECOGNITION)|SPFEI(SPEI_HYPOTHESIS)|SPFEI(SPEI_SOUND_START)|SPFEI(SPEI_FALSE_RECOGNITION);
        hr=reco->SetInterest(interest,interest);
    }
    if(SUCCEEDED(hr)){stage="grammar";hr=reco->CreateGrammar(1,&grammar);}
    if(SUCCEEDED(hr)){stage="dictation";hr=grammar->LoadDictation(nullptr,SPLO_STATIC);}
    if(SUCCEEDED(hr)){stage="listening";hr=grammar->SetDictationState(SPRS_ACTIVE);}
    ULONGLONG started=GetTickCount64();
    while(SUCCEEDED(hr)&&GetTickCount64()-started<20000) {
        if(cancelled&&cancelled(context)){result=0;ending="cancelled";break;}
        DWORD wait=WaitForSingleObject(reco->GetNotifyEventHandle(),100);
        if(wait==WAIT_TIMEOUT)continue;
        if(wait!=WAIT_OBJECT_0){hr=E_FAIL;stage="wait";break;}
        SPEVENT event={};ULONG fetched=0;
        while(reco->GetEvents(1,&event,&fetched)==S_OK&&fetched) {
            ++events;
            if(event.eEventId==SPEI_HYPOTHESIS)++hypotheses;
            if(event.eEventId==SPEI_SOUND_START)++sounds;
            if(event.eEventId==SPEI_RECOGNITION&&event.lParam) {
                ISpRecoResult *recognized=(ISpRecoResult*)event.lParam;WCHAR *text=nullptr;
                stage="result";
                hr=recognized->GetText(SP_GETWHOLEPHRASE,SP_GETWHOLEPHRASE,TRUE,&text,nullptr);
                if(SUCCEEDED(hr)&&text&&*text) {
                    result=WideCharToMultiByte(CP_UTF8,0,text,-1,output,(int)capacity,nullptr,nullptr)?1:-1;
                    ending=result==1?"recognized":"buffer_error";
                }
                CoTaskMemFree(text);
            }
            if(event.elParamType==SPET_LPARAM_IS_OBJECT&&event.lParam)((IUnknown*)event.lParam)->Release();
            else if(event.elParamType==SPET_LPARAM_IS_STRING&&event.lParam)CoTaskMemFree((void*)event.lParam);
            if(result==1)break;
        }
        if(result==1)break;
    }
    if(SUCCEEDED(hr)&&result<0&&GetTickCount64()-started>=20000){result=-2;ending="timeout_no_text";}
    if(diagnostic&&diagnosticCapacity)snprintf(diagnostic,diagnosticCapacity,
        "SAPI1 stage=%s hr=0x%08lx locale=%04lx ui_locale=%04x events=%d partial=%d sound=%d end=%s",
        stage,(unsigned long)hr,engineLanguage,(unsigned int)GetUserDefaultUILanguage(),events,hypotheses,sounds,ending);
    if(grammar){grammar->SetDictationState(SPRS_INACTIVE);grammar->Release();}
    if(reco)reco->Release();if(recognizer)recognizer->Release();
    if(SUCCEEDED(apartment))CoUninitialize();return result;
}
int castor_system_recognize(char *output,size_t capacity,int (*cancelled)(void*),void *context) {
    return castor_system_recognize_diagnostic(output,capacity,nullptr,0,cancelled,context);
}
#else
int castor_system_voices(char *output,size_t capacity){return -1;}
int castor_system_recognizers(char *output,size_t capacity){return -1;}
int castor_system_speak(const char *text,const char *tokenId,int (*cancelled)(void*),void *context){return -1;}
int castor_system_recognize(char *output,size_t capacity,int (*cancelled)(void*),void *context){return -1;}
int castor_system_recognize_diagnostic(char *output,size_t capacity,char *diagnostic,size_t diagnosticCapacity,int (*cancelled)(void*),void *context){return -1;}
#endif

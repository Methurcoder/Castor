#include "CPlatformImage.h"
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <wincodec.h>
struct ImageDecoder {
    HRESULT com;IWICImagingFactory *factory=nullptr;IWICStream *stream=nullptr;
    IWICBitmapDecoder *decoder=nullptr;IWICBitmapFrameDecode *frame=nullptr;
    ImageDecoder(const uint8_t *data,size_t length) {
        com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
        if ((FAILED(com)&&com!=RPC_E_CHANGED_MODE) || !length || length>64*1024*1024) return;
        if (FAILED(CoCreateInstance(__uuidof(WICImagingFactory),nullptr,CLSCTX_INPROC_SERVER,__uuidof(IWICImagingFactory),(void**)&factory)))return;
        if (FAILED(factory->CreateStream(&stream)))return;
        if (FAILED(stream->InitializeFromMemory((BYTE*)data,(DWORD)length)))return;
        if (FAILED(factory->CreateDecoderFromStream(stream,nullptr,WICDecodeMetadataCacheOnDemand,&decoder)))return;
        if (FAILED(decoder->GetFrame(0,&frame))) frame=nullptr;
    }
    ~ImageDecoder(){if(frame)frame->Release();if(decoder)decoder->Release();if(stream)stream->Release();if(factory)factory->Release();if(SUCCEEDED(com))CoUninitialize();}
};
int castor_image_info(const uint8_t *data,size_t length,int32_t *width,int32_t *height) {
    ImageDecoder image(data,length);UINT w=0,h=0;
    if (!image.frame || FAILED(image.frame->GetSize(&w,&h)) || !w || !h || w>INT32_MAX || h>INT32_MAX)return 0;
    *width=(int32_t)w;*height=(int32_t)h;return 1;
}
int castor_image_decode(const uint8_t *data,size_t length,uint8_t *rgba,int32_t width,int32_t height) {
    if(width<1||height<1||width>4096||height>4096)return 0;
    ImageDecoder image(data,length);UINT w=0,h=0;IWICFormatConverter *converter=nullptr;
    if(!image.frame||FAILED(image.frame->GetSize(&w,&h))||w!=(UINT)width||h!=(UINT)height||FAILED(image.factory->CreateFormatConverter(&converter)))return 0;
    HRESULT result=converter->Initialize(image.frame,GUID_WICPixelFormat32bppRGBA,WICBitmapDitherTypeNone,nullptr,0,WICBitmapPaletteTypeCustom);
    if(SUCCEEDED(result)) result=converter->CopyPixels(nullptr,(UINT)width*4,(UINT)width*(UINT)height*4,rgba);
    converter->Release();return SUCCEEDED(result)?1:0;
}
#elif defined(__APPLE__)
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
static CGImageSourceRef source(const uint8_t *data,size_t length) {
    if(!length||length>64*1024*1024)return nullptr;
    CFDataRef bytes=CFDataCreate(kCFAllocatorDefault,data,(CFIndex)length);
    if(!bytes)return nullptr;
    CGImageSourceRef image=CGImageSourceCreateWithData(bytes,nullptr);CFRelease(bytes);return image;
}
int castor_image_info(const uint8_t *data,size_t length,int32_t *width,int32_t *height) {
    CGImageSourceRef image=source(data,length);if(!image)return 0;
    CFDictionaryRef properties=CGImageSourceCopyPropertiesAtIndex(image,0,nullptr);CFRelease(image);
    if(!properties)return 0;
    CFTypeRef w=CFDictionaryGetValue(properties,kCGImagePropertyPixelWidth),h=CFDictionaryGetValue(properties,kCGImagePropertyPixelHeight);
    int valid=w&&h&&CFGetTypeID(w)==CFNumberGetTypeID()&&CFGetTypeID(h)==CFNumberGetTypeID()&&
        CFNumberGetValue((CFNumberRef)w,kCFNumberSInt32Type,width)&&CFNumberGetValue((CFNumberRef)h,kCFNumberSInt32Type,height)&&*width>0&&*height>0;
    CFRelease(properties);return valid;
}
int castor_image_decode(const uint8_t *data,size_t length,uint8_t *rgba,int32_t width,int32_t height) {
    if(width<1||height<1||width>4096||height>4096)return 0;
    CGImageSourceRef sourceImage=source(data,length);if(!sourceImage)return 0;
    CGImageRef image=CGImageSourceCreateImageAtIndex(sourceImage,0,nullptr);CFRelease(sourceImage);
    if(!image)return 0;
    if(CGImageGetWidth(image)!=(size_t)width||CGImageGetHeight(image)!=(size_t)height){CGImageRelease(image);return 0;}
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(rgba,width,height,8,(size_t)width*4,color,kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(color);
    if(!context){CGImageRelease(image);return 0;}
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);CGImageRelease(image);
    for(size_t i=0;i<(size_t)width*height;++i){unsigned alpha=rgba[i*4+3];if(alpha){for(int c=0;c<3;++c){unsigned value=((unsigned)rgba[i*4+c]*255+alpha/2)/alpha;rgba[i*4+c]=(uint8_t)(value>255?255:value);}}}
    return 1;
}
#else
int castor_image_info(const uint8_t *data,size_t length,int32_t *width,int32_t *height){return 0;}
int castor_image_decode(const uint8_t *data,size_t length,uint8_t *rgba,int32_t width,int32_t height){return 0;}
#endif

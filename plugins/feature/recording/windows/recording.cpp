#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "recording.h"
#include "native/windows/resource.h"
#include "native/shared/recording_plan.h"
#include "platform/shared/media/output_file.h"
#include "moonbit.h"
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wrl/client.h>
#include <shlobj.h>
#include <shellapi.h>
#include <propvarutil.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <thread>
#include <vector>

extern "C" {
int32_t native_video_open(int32_t, int32_t, int32_t, int32_t);
int32_t native_video_resume(int32_t, int32_t, int32_t, int32_t, moonbit_string_t);
int32_t native_video_trim(int32_t, int32_t, int32_t);
int32_t native_video_cut(int32_t, int32_t, int32_t);
int32_t native_video_clear_cuts(int32_t);
int32_t native_video_crop(int32_t, int32_t, int32_t, int32_t, int32_t);
int32_t native_video_reset_crop(int32_t);
int32_t native_video_undo(int32_t);
int32_t native_video_redo(int32_t);
int32_t native_video_reset(int32_t);
int32_t native_video_duration(int32_t);
int32_t native_video_segment_count(int32_t);
int32_t native_video_segment_value(int32_t, int32_t, int32_t);
int32_t native_video_crop_value(int32_t, int32_t);
int32_t native_video_edit_value(int32_t, int32_t);
moonbit_string_t native_video_snapshot(int32_t);
moonbit_string_t native_video_error(int32_t);
void native_video_close(int32_t);
}

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;
namespace {
constexpr LONGLONG second = 10000000;
constexpr DWORD videoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD audioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr DWORD allStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD mediaSource = static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);
constexpr UINT doneMessage = WM_APP + 0x62;
constexpr wchar_t hostClass[] = L"MoojiCut.Recording.WorkerHost";
constexpr wchar_t editorClass[] = L"MoojiCut.Recording.Editor";
enum { TrimStart=9100, TrimEnd, CutStart, CutEnd, CropX, CropY, CropW, CropH,
       ApplyTrim, AddCut, ClearCuts, ApplyCrop, ResetCrop, Undo, Redo, Reset,
       PreviewSource, PreviewEdited, Confirm, CloseEditor, OpenDraft };
struct Failure { HRESULT code; std::wstring stage; };
void check(HRESULT hr, const wchar_t *stage) { if (FAILED(hr)) throw Failure{hr, stage}; }
MCCoreRecordingPlan recordingPlan(int32_t width, int32_t height) {
    MCCoreRecordingPlan plan=mc_core_recording_plan(MC_RECORDING_WINDOWS,width,height,0);
    if(plan.width<=0 || plan.height<=0 || plan.frames_per_second<=0 || plan.system_audio || plan.microphone || plan.countdown_seconds)
        throw Failure{E_INVALIDARG,L"无法规划当前显示器的录制参数"};
    return plan;
}
std::wstring description(const Failure &failure) {
    wchar_t value[32]; swprintf_s(value, L" (0x%08lX)", static_cast<unsigned long>(failure.code));
    std::wstring message = failure.stage + std::wstring(value);
    wchar_t *system = nullptr;
    if (FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, static_cast<DWORD>(failure.code), 0, reinterpret_cast<LPWSTR>(&system), 0, nullptr)) {
        message += L"\n"; message += system; LocalFree(system);
    }
    return message;
}
struct MediaRuntime {
    bool initialized = false, started = false;
    MediaRuntime() {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (hr != RPC_E_CHANGED_MODE) check(hr, L"无法初始化视频组件");
        initialized = SUCCEEDED(hr);
        hr = MFStartup(MF_VERSION);
        if (FAILED(hr)) { if (initialized) CoUninitialize(); throw Failure{hr, L"无法启动 Windows Media Foundation；Windows N 版需要媒体功能包"}; }
        started = true;
    }
    ~MediaRuntime() { if (started) MFShutdown(); if (initialized) CoUninitialize(); }
};
std::wstring identifier() {
    GUID guid; check(CoCreateGuid(&guid), L"无法生成文件名"); wchar_t text[48];
    StringFromGUID2(guid, text, 48); return text;
}
fs::path applicationDirectory() {
    PWSTR directory = nullptr; check(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &directory), L"无法访问用户数据目录");
    fs::path path = fs::path(directory) / L"MoojiCut"; CoTaskMemFree(directory); return path;
}
std::wstring takeString(moonbit_string_t value) {
    std::wstring result(reinterpret_cast<const wchar_t *>(value), static_cast<size_t>(Moonbit_array_length(value)));
    moonbit_decref(value); return result;
}
moonbit_string_t toString(const std::wstring &value) {
    moonbit_string_t result = moonbit_make_string_raw(static_cast<int32_t>(value.size()));
    memcpy(result, value.data(), value.size()*sizeof(wchar_t)); return result;
}
std::string utf8(const std::wstring &value) {
    if (value.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!size) throw Failure{HRESULT_FROM_WIN32(GetLastError()), L"无法编码草稿"};
    std::string result(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr); return result;
}
std::wstring fromUtf8(const std::string &value) {
    if (value.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (!size) throw Failure{HRESULT_FROM_WIN32(GetLastError()), L"草稿文本损坏"};
    std::wstring result(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size); return result;
}

struct Encoder {
    ComPtr<IMFSinkWriter> writer;
    bool finalizeAttempted = false;
    DWORD stream = 0;
    UINT32 width, height;
    Encoder(const fs::path &path, UINT32 w, UINT32 h, UINT32 frameRate) : width(w), height(h) {
        ComPtr<IMFAttributes> attributes; check(MFCreateAttributes(&attributes, 2), L"无法配置编码器");
        check(attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE), L"无法配置编码器");
        check(MFCreateSinkWriterFromURL(path.c_str(), nullptr, attributes.Get(), &writer), L"无法创建 MP4 文件");
        ComPtr<IMFMediaType> output, input;
        check(MFCreateMediaType(&output), L"无法配置视频格式");
        check(output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), L"无法配置视频格式");
        check(output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264), L"无法配置 H.264");
        check(output->SetUINT32(MF_MT_AVG_BITRATE, std::max<UINT32>(500000, std::min<UINT32>(8000000, w*h*2))), L"无法配置码率");
        check(output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive), L"无法配置帧格式");
        check(MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, w, h), L"无法配置视频尺寸");
        check(MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, frameRate, 1), L"无法配置帧率");
        check(MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1), L"无法配置像素比例");
        check(writer->AddStream(output.Get(), &stream), L"系统 H.264 编码器不可用；Windows N 版请安装媒体功能包");
        check(MFCreateMediaType(&input), L"无法配置输入画面");
        check(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), L"无法配置输入画面");
        check(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32), L"无法配置 RGB 画面");
        check(input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive), L"无法配置输入帧");
        check(input->SetUINT32(MF_MT_DEFAULT_STRIDE, w*4), L"无法配置画面行距");
        check(MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, w, h), L"无法配置输入尺寸");
        check(MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, frameRate, 1), L"无法配置输入帧率");
        check(MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1), L"无法配置输入像素比例");
        check(writer->SetInputMediaType(stream, input.Get(), nullptr), L"系统无法编码此视频尺寸或像素格式");
        check(writer->BeginWriting(), L"无法开始编码视频");
    }
    void frame(const BYTE *pixels, LONGLONG time, LONGLONG duration) {
        DWORD size = width*height*4;
        ComPtr<IMFMediaBuffer> buffer; check(MFCreateMemoryBuffer(size, &buffer), L"无法分配视频帧");
        BYTE *data = nullptr; check(buffer->Lock(&data, nullptr, nullptr), L"无法写入视频帧");
        memcpy(data, pixels, size); buffer->Unlock(); check(buffer->SetCurrentLength(size), L"无法写入视频帧");
        ComPtr<IMFSample> sample; check(MFCreateSample(&sample), L"无法创建视频帧");
        check(sample->AddBuffer(buffer.Get()), L"无法添加视频帧");
        check(sample->SetSampleTime(time), L"无法设置视频时间");
        check(sample->SetSampleDuration(std::max<LONGLONG>(duration, 1)), L"无法设置视频时长");
        check(writer->WriteSample(stream, sample.Get()), L"视频写入失败，请检查磁盘空间");
    }
    void finish() {
        finalizeAttempted = true;
        HRESULT result = writer->Finalize();
        writer.Reset();
        check(result, L"无法完成 MP4 文件，请检查磁盘空间");
    }
    void finishAfterFailure() noexcept {
        // Best effort: Finalize writes container headers. Preserve the primary
        // capture error and never retry a failed Finalize on the same writer.
        if (!finalizeAttempted && writer) {
            finalizeAttempted = true;
            writer->Finalize();
            writer.Reset();
        }
    }
};

struct Decoder {
    ComPtr<IMFSourceReader> reader;
    UINT32 frameRate;
    // H.264 decoding can expand the backing frame to a macroblock boundary.
    // Editing coordinates always refer to the valid display aperture instead.
    UINT32 width = 0, height = 0;
    UINT32 bufferWidth = 0, bufferHeight = 0, offsetX = 0, offsetY = 0;
    LONG stride = 0;
    LONGLONG duration = 0;
    void readFormat() {
        ComPtr<IMFMediaType> actual;
        check(reader->GetCurrentMediaType(videoStream, &actual), L"无法读取视频格式");
        UINT32 w=0,h=0,value=0;GUID subtype={};
        check(MFGetAttributeSize(actual.Get(),MF_MT_FRAME_SIZE,&w,&h),L"无法读取视频尺寸");
        check(actual->GetGUID(MF_MT_SUBTYPE,&subtype),L"无法读取视频像素格式");
        if(!w||!h||w>8192||h>8192)throw Failure{E_INVALIDARG,L"视频尺寸超出支持范围"};
        MFVideoArea area={};UINT32 areaBytes=0;const char *aperture="minimum";
        HRESULT hr=actual->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE,reinterpret_cast<UINT8 *>(&area),sizeof(area),&areaBytes);
        if(hr==MF_E_ATTRIBUTENOTFOUND){aperture="geometric";hr=actual->GetBlob(MF_MT_GEOMETRIC_APERTURE,reinterpret_cast<UINT8 *>(&area),sizeof(area),&areaBytes);}
        if(hr==MF_E_ATTRIBUTENOTFOUND){aperture="full";area={};area.Area.cx=static_cast<LONG>(w);area.Area.cy=static_cast<LONG>(h);}
        else {check(hr,L"无法读取视频有效画面范围");if(areaBytes!=sizeof(area))throw Failure{E_INVALIDARG,L"视频有效画面范围损坏"};}
        if(area.OffsetX.fract||area.OffsetY.fract||area.OffsetX.value<0||area.OffsetY.value<0||area.Area.cx<=0||area.Area.cy<=0||
            static_cast<UINT32>(area.OffsetX.value)+static_cast<UINT32>(area.Area.cx)>w||
            static_cast<UINT32>(area.OffsetY.value)+static_cast<UINT32>(area.Area.cy)>h)
            throw Failure{E_INVALIDARG,L"视频有效画面范围无效"};
        UINT32 visibleWidth=static_cast<UINT32>(area.Area.cx),visibleHeight=static_cast<UINT32>(area.Area.cy);
        LONG newStride=0;
        if(SUCCEEDED(actual->GetUINT32(MF_MT_DEFAULT_STRIDE,&value)))newStride=static_cast<LONG>(value);
        else check(MFGetStrideForBitmapInfoHeader(subtype.Data1,w,&newStride),L"无法读取视频行距");
        wchar_t guid[48]={};StringFromGUID2(subtype,guid,48);
        std::fprintf(stderr,"MF decoder format: buffer=%ux%u visible=%ux%u offset=%d,%d aperture=%s stride=%ld subtype=%s\n",
            w,h,visibleWidth,visibleHeight,area.OffsetX.value,area.OffsetY.value,aperture,newStride,utf8(guid).c_str());
        if(subtype!=MFVideoFormat_RGB32)throw Failure{E_UNEXPECTED,L"视频解码器未返回 RGB32 画面"};
        if(width&&(width!=visibleWidth||height!=visibleHeight))throw Failure{E_UNEXPECTED,L"录屏有效画面尺寸在处理中发生变化"};
        if(std::llabs(static_cast<LONGLONG>(newStride))<static_cast<LONGLONG>(w)*4)
            throw Failure{E_UNEXPECTED,L"视频画面行距过小"};
        width=visibleWidth;height=visibleHeight;bufferWidth=w;bufferHeight=h;
        offsetX=static_cast<UINT32>(area.OffsetX.value);offsetY=static_cast<UINT32>(area.OffsetY.value);stride=newStride;
    }
    Decoder(const fs::path &path, UINT32 fallbackFrameRate) : frameRate(fallbackFrameRate) {
        ComPtr<IMFAttributes> attributes; check(MFCreateAttributes(&attributes, 2), L"无法配置视频解码");
        check(attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE), L"无法配置视频解码");
        check(MFCreateSourceReaderFromURL(path.c_str(), attributes.Get(), &reader), L"无法读取录屏文件");
        check(reader->SetStreamSelection(allStreams, FALSE), L"无法选择视频轨道");
        check(reader->SetStreamSelection(videoStream, TRUE), L"录屏中没有视频轨道");
        ComPtr<IMFMediaType> input; check(MFCreateMediaType(&input), L"无法配置解码格式");
        input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video); input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
        check(reader->SetCurrentMediaType(videoStream, nullptr, input.Get()), L"无法将视频解码为 RGB");
        readFormat();
        PROPVARIANT length; PropVariantInit(&length);
        HRESULT hr = reader->GetPresentationAttribute(mediaSource, MF_PD_DURATION, &length);
        if (SUCCEEDED(hr) && length.vt == VT_UI8) duration = static_cast<LONGLONG>(length.uhVal.QuadPart);
        PropVariantClear(&length);
        if (duration <= 0) throw Failure{E_INVALIDARG, L"无法读取视频时长"};
    }
    bool next(std::vector<BYTE> &pixels, LONGLONG &time, LONGLONG &length) {
        for (;;) {
            DWORD flags = 0; ComPtr<IMFSample> sample;
            check(reader->ReadSample(videoStream, 0, nullptr, &flags, &time, &sample), L"无法解码视频帧");
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) return false;
            if (flags & MF_SOURCE_READERF_ERROR) throw Failure{E_FAIL, L"视频解码器报告错误"};
            if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) readFormat();
            if (!sample) continue;
            length = second/frameRate; sample->GetSampleDuration(&length);
            if (length <= 0) length = second/frameRate;
            ComPtr<IMFMediaBuffer> buffer; check(sample->ConvertToContiguousBuffer(&buffer), L"无法读取解码画面");
            pixels.resize(static_cast<size_t>(width)*height*4);
            ComPtr<IMF2DBuffer> twoD;
            BYTE *first = nullptr; LONG pitch = stride; DWORD bytes = 0;
            bool locked2D = SUCCEEDED(buffer.As(&twoD));
            if (locked2D) check(twoD->Lock2D(&first, &pitch), L"无法读取解码画面");
            else {
                check(buffer->Lock(&first, nullptr, &bytes), L"无法读取解码画面");
                size_t required = static_cast<size_t>(std::llabs(static_cast<LONGLONG>(pitch)))*(bufferHeight-1)+bufferWidth*4;
                if (required>bytes) { buffer->Unlock(); throw Failure{E_UNEXPECTED, L"视频画面缓冲区不完整"}; }
                if (pitch < 0) first += static_cast<size_t>(bufferHeight-1)*static_cast<size_t>(-static_cast<LONGLONG>(pitch));
            }
            if(std::llabs(static_cast<LONGLONG>(pitch))<static_cast<LONGLONG>(bufferWidth)*4){
                if(locked2D)twoD->Unlock2D();else buffer->Unlock();throw Failure{E_UNEXPECTED,L"视频画面行距过小"};
            }
            first+=static_cast<ptrdiff_t>(offsetY)*pitch+static_cast<ptrdiff_t>(offsetX)*4;
            for (UINT32 y=0; y<height; y++) memcpy(pixels.data()+static_cast<size_t>(y)*width*4, first+static_cast<ptrdiff_t>(y)*pitch, width*4);
            if (locked2D) twoD->Unlock2D(); else buffer->Unlock();
            return true;
        }
    }
    bool hasAudio() {
        ComPtr<IMFMediaType> audio;
        return SUCCEEDED(reader->GetNativeMediaType(audioStream, 0, &audio));
    }
};
struct Segment { LONGLONG start, end, output; };
struct Plan { UINT32 x=0,y=0,width=0,height=0; LONGLONG duration=0; std::vector<Segment> segments; };
Plan planFor(int32_t session) {
    Plan plan;
    int32_t x=native_video_crop_value(session,0), y=native_video_crop_value(session,1);
    int32_t w=native_video_crop_value(session,2), h=native_video_crop_value(session,3);
    if(x<0 || y<0 || w<2 || h<2) throw Failure{E_INVALIDARG,L"MoonBit 返回无效画面范围"};
    plan.x=static_cast<UINT32>(x); plan.y=static_cast<UINT32>(y); plan.width=static_cast<UINT32>(w); plan.height=static_cast<UINT32>(h);
    plan.duration=static_cast<LONGLONG>(native_video_duration(session))*10000;
    int32_t count=native_video_segment_count(session);
    for(int32_t i=0;i<count;i++) {
        int32_t start=native_video_segment_value(session,i,0), end=native_video_segment_value(session,i,1), output=native_video_segment_value(session,i,2);
        if(start<0 || end<=start || output<0) throw Failure{E_INVALIDARG,L"MoonBit 返回无效视频片段"};
        plan.segments.push_back({static_cast<LONGLONG>(start)*10000,static_cast<LONGLONG>(end)*10000,static_cast<LONGLONG>(output)*10000});
    }
    if(plan.segments.empty() || plan.duration<=0) throw Failure{E_INVALIDARG,L"视频没有可导出的片段"};
    return plan;
}
void exportVideo(const fs::path &source, const fs::path &target, const Plan &plan, UINT32 frameRate, std::atomic<bool> &cancel, std::atomic<int> &progress) {
    Decoder decoder(source,frameRate);
    if(plan.x+plan.width>decoder.width || plan.y+plan.height>decoder.height) throw Failure{E_INVALIDARG,L"裁剪范围超出视频画面"};
    Encoder encoder(target,plan.width,plan.height,frameRate);
    std::vector<BYTE> pixels, cropped(static_cast<size_t>(plan.width)*plan.height*4);
    LONGLONG time=0,length=0, written=0; size_t first=0;
    while(decoder.next(pixels,time,length)) {
        if(cancel.load()) throw Failure{HRESULT_FROM_WIN32(ERROR_CANCELLED),L"导出已取消"};
        while(first<plan.segments.size() && time>=plan.segments[first].end) first++;
        if(first==plan.segments.size()) break;
        bool copied=false;
        for(size_t i=first;i<plan.segments.size() && plan.segments[i].start<time+length;i++) {
            const Segment &segment=plan.segments[i];
            LONGLONG begin=std::max(time,segment.start), end=std::min(time+length,segment.end);
            if(end<=begin) continue;
            if(!copied) {
                for(UINT32 y=0;y<plan.height;y++) memcpy(cropped.data()+static_cast<size_t>(y)*plan.width*4,
                    pixels.data()+(static_cast<size_t>(plan.y+y)*decoder.width+plan.x)*4, plan.width*4);
                copied=true;
            }
            LONGLONG position=segment.output+begin-segment.start;
            encoder.frame(cropped.data(),position,end-begin); written=position+end-begin;
        }
        progress.store(static_cast<int>(std::min<LONGLONG>(99,written*100/plan.duration)));
    }
    if(cancel.load()) throw Failure{HRESULT_FROM_WIN32(ERROR_CANCELLED),L"导出已取消"};
    if(!written) throw Failure{E_UNEXPECTED,L"视频中没有可保留的画面"};
    encoder.finish(); progress.store(100);
}

struct DesktopSurface {
    HDC screen=nullptr,memory=nullptr; HBITMAP bitmap=nullptr; HGDIOBJ old=nullptr; BYTE *pixels=nullptr;
    DesktopSurface(UINT32 width,UINT32 height) {
        screen=GetDC(nullptr); memory=CreateCompatibleDC(screen);
        BITMAPINFO info={}; info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth=static_cast<LONG>(width);
        info.bmiHeader.biHeight=-static_cast<LONG>(height); info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32; info.bmiHeader.biCompression=BI_RGB;
        bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,reinterpret_cast<void **>(&pixels),nullptr,0);
        if(!screen || !memory || !bitmap) { cleanup(); throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法准备录屏画面"}; }
        old=SelectObject(memory,bitmap); SetStretchBltMode(memory,HALFTONE); SetBrushOrgEx(memory,0,0,nullptr);
    }
    void cleanup() { if(old&&memory) SelectObject(memory,old); if(bitmap) DeleteObject(bitmap); if(memory) DeleteDC(memory); if(screen) ReleaseDC(nullptr,screen); }
    ~DesktopSurface() { cleanup(); }
};
void recordDesktop(const fs::path &target, RECT bounds, UINT32 width, UINT32 height, UINT32 frameRate, std::atomic<bool> &stop) {
    Encoder encoder(target,width,height,frameRate);
    try {
        DesktopSurface surface(width,height);
        // Let the start dialog disappear from the compositor before the first frame.
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        std::vector<BYTE> pending(static_cast<size_t>(width)*height*4);
        LARGE_INTEGER frequency,origin,now; QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&origin);
        LONGLONG last=0; bool haveFrame=false;
        auto next=std::chrono::steady_clock::now();
        do {
            if(!StretchBlt(surface.memory,0,0,static_cast<int>(width),static_cast<int>(height),surface.screen,bounds.left,bounds.top,
                bounds.right-bounds.left,bounds.bottom-bounds.top,SRCCOPY|CAPTUREBLT)) throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法读取主显示器；安全桌面或受保护内容不可录制"};
            CURSORINFO cursor={};cursor.cbSize=sizeof(cursor);
            if(GetCursorInfo(&cursor)&&(cursor.flags&CURSOR_SHOWING)&&PtInRect(&bounds,cursor.ptScreenPos)) {
                ICONINFO icon={};
                if(GetIconInfo(cursor.hCursor,&icon)) {
                    double sx=static_cast<double>(width)/(bounds.right-bounds.left),sy=static_cast<double>(height)/(bounds.bottom-bounds.top);
                    DrawIconEx(surface.memory,static_cast<int>((cursor.ptScreenPos.x-bounds.left-static_cast<LONG>(icon.xHotspot))*sx),
                        static_cast<int>((cursor.ptScreenPos.y-bounds.top-static_cast<LONG>(icon.yHotspot))*sy),cursor.hCursor,
                        std::max(1,static_cast<int>(GetSystemMetrics(SM_CXCURSOR)*sx)),std::max(1,static_cast<int>(GetSystemMetrics(SM_CYCURSOR)*sy)),0,nullptr,DI_NORMAL);
                    if(icon.hbmMask)DeleteObject(icon.hbmMask);if(icon.hbmColor)DeleteObject(icon.hbmColor);
                }
            }
            GdiFlush(); QueryPerformanceCounter(&now);
            LONGLONG timestamp=(now.QuadPart-origin.QuadPart)*second/frequency.QuadPart;
            if(!haveFrame) { origin=now; timestamp=0; }
            else encoder.frame(pending.data(),last,std::max<LONGLONG>(1,timestamp-last));
            memcpy(pending.data(),surface.pixels,pending.size()); last=timestamp; haveFrame=true;
            next+=std::chrono::microseconds(1000000/frameRate);
            while(!stop.load() && std::chrono::steady_clock::now()<next) Sleep(5);
        } while(!stop.load());
        QueryPerformanceCounter(&now);
        LONGLONG end=(now.QuadPart-origin.QuadPart)*second/frequency.QuadPart;
        if(haveFrame) encoder.frame(pending.data(),last,std::max<LONGLONG>(10000,end-last));
        encoder.finish();
    } catch (...) {
        encoder.finishAfterFailure();
        throw;
    }
}

enum class JobKind { None, Recording, Preview, Confirm };
struct JobResult { JobKind kind; bool success=false,cancelled=false,published=false; std::wstring error; fs::path path; UINT32 width=0,height=0; int32_t duration=0; };
struct RecordingState {
    HINSTANCE instance=nullptr; HWND owner=nullptr,host=nullptr,editor=nullptr,status=nullptr,summary=nullptr;
    HFONT font=nullptr; HWND fields[8]={}; std::vector<HWND> controls;
    std::thread worker; std::atomic<bool> stop{false},cancel{false}; std::atomic<int> progress{0};
    JobKind kind=JobKind::None; bool closeAfter=false,prompt=false,pendingCut=false; int32_t session=0; fs::path directory,source;
    ~RecordingState(){stop.store(true);cancel.store(true);if(worker.joinable())worker.join();}
} state;
void notify() { if(state.owner) PostMessageW(state.owner,MOOJICUT_RECORDING_STATE_CHANGED,0,0); }
void setStatus(const std::wstring &text) { if(state.status) SetWindowTextW(state.status,text.c_str()); }
void showFailure(const std::wstring &message) { MessageBoxW(state.editor?state.editor:state.owner,message.c_str(),L"Mooji Cut",MB_OK|MB_ICONWARNING); }
void saveDraft() {
    std::wstring document=takeString(native_video_snapshot(state.session));
    if(document.empty()) throw Failure{E_FAIL,L"无法保存 MoonBit 编辑草稿"};
    std::string data=utf8(document); fs::path temporary=state.directory/L"edit.json.tmp";
    { std::ofstream file(temporary,std::ios::binary|std::ios::trunc); file.write(data.data(),static_cast<std::streamsize>(data.size())); if(!file) throw Failure{E_FAIL,L"无法写入编辑草稿，请检查磁盘空间"}; }
    if(!MoveFileExW(temporary.c_str(),(state.directory/L"edit.json").c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法保存编辑草稿"};
}
void putNumber(HWND field,int32_t value,bool milliseconds) {
    wchar_t text[64]; if(milliseconds) swprintf_s(text,L"%.3f",static_cast<double>(value)/1000); else swprintf_s(text,L"%d",value); SetWindowTextW(field,text);
}
void refresh() {
    if(!state.session || !state.editor) return;
    putNumber(state.fields[0],native_video_edit_value(state.session,0),true); putNumber(state.fields[1],native_video_edit_value(state.session,1),true);
    for(int i=0;i<4;i++) putNumber(state.fields[4+i],native_video_crop_value(state.session,i),false);
    EnableWindow(GetDlgItem(state.editor,Undo),native_video_edit_value(state.session,3)>0);
    EnableWindow(GetDlgItem(state.editor,Redo),native_video_edit_value(state.session,4)>0);
    wchar_t text[256]; swprintf_s(text,L"成片 %.3f 秒 · %d × %d · 删除区间 %d 个 · 无音轨（静音录屏）",
        static_cast<double>(native_video_duration(state.session))/1000,native_video_crop_value(state.session,2),native_video_crop_value(state.session,3),native_video_edit_value(state.session,5));
    SetWindowTextW(state.summary,text); setStatus(L"编辑已应用并保存。确认后才会复制视频文件。");
}
bool number(HWND field,int32_t &result,bool milliseconds) {
    wchar_t text[80]; GetWindowTextW(field,text,80); wchar_t *end=nullptr; double value=wcstod(text,&end);
    while(end && iswspace(*end)) end++;
    double scaled=milliseconds?std::round(value*1000):value;
    if(end==text || (end&&*end) || !std::isfinite(scaled) || scaled<0 || scaled>604800000 || (!milliseconds&&std::floor(scaled)!=scaled)) {
        setStatus(milliseconds?L"请输入有效秒数，例如 1.250。":L"像素值需要填写非负整数。");return false;
    }
    result=static_cast<int32_t>(scaled);return true;
}
void applied(int32_t success) {
    if(!success){setStatus(takeString(native_video_error(state.session)));return;}
    try{saveDraft();refresh();}catch(const Failure &error){setStatus(description(error));}
}
bool noPendingInputs() {
    int32_t values[6];
    if(!number(state.fields[0],values[0],true)||!number(state.fields[1],values[1],true))return false;
    for(int i=0;i<4;i++)if(!number(state.fields[4+i],values[2+i],false))return false;
    bool same=values[0]==native_video_edit_value(state.session,0)&&values[1]==native_video_edit_value(state.session,1);
    for(int i=0;i<4;i++)same=same&&values[2+i]==native_video_crop_value(state.session,i);
    if(!same)setStatus(L"还有未应用的裁剪或画面调整，请先点击对应的“应用”按钮。");
    if(same&&state.pendingCut){int32_t start=0,end=0;if(!number(state.fields[2],start,true)||!number(state.fields[3],end,true))return false;
        if(start!=0||end!=0){setStatus(L"还有未添加的删除区间，请点击“添加删除区间”，或将两项都清为 0。");return false;}state.pendingCut=false;}
    return same;
}
bool copyFile(HWND owner,const fs::path &file) {
    std::wstring path=file.wstring();SIZE_T size=sizeof(DROPFILES)+(path.size()+2)*sizeof(wchar_t);
    HGLOBAL memory=GlobalAlloc(GMEM_MOVEABLE|GMEM_ZEROINIT,size);if(!memory)return false;
    DROPFILES *drop=static_cast<DROPFILES *>(GlobalLock(memory));if(!drop){GlobalFree(memory);return false;}
    drop->pFiles=sizeof(DROPFILES);drop->fWide=TRUE;memcpy(reinterpret_cast<BYTE *>(drop)+sizeof(DROPFILES),path.c_str(),(path.size()+1)*sizeof(wchar_t));GlobalUnlock(memory);
    if(!OpenClipboard(owner)){GlobalFree(memory);return false;}bool copied=EmptyClipboard()&&SetClipboardData(CF_HDROP,memory)!=nullptr;CloseClipboard();if(!copied)GlobalFree(memory);return copied;
}
void openEditor(UINT32 width,UINT32 height,int32_t duration);
void complete(JobResult *raw) {
    std::unique_ptr<JobResult> result(raw);if(state.worker.joinable())state.worker.join();
    state.kind=JobKind::None;notify();
    for(HWND control:state.controls)EnableWindow(control,TRUE);
    if(result->kind!=JobKind::Recording && state.cancel.load()) {
        result->cancelled=true;result->success=false;
        // The final path may belong to a pre-existing file if publication failed.
        if(result->published){std::error_code ignored;fs::remove(result->path,ignored);}
    }
    if(!result->success) {
        if(result->cancelled)setStatus(L"导出已取消，原片与草稿仍然保留。");else showFailure(result->error);
        if(state.closeAfter&&state.editor){state.closeAfter=false;DestroyWindow(state.editor);}return;
    }
    if(result->kind==JobKind::Recording){openEditor(result->width,result->height,result->duration);return;}
    refresh();
    if(result->kind==JobKind::Preview){ShellExecuteW(state.editor,L"open",result->path.c_str(),nullptr,nullptr,SW_SHOWNORMAL);setStatus(L"成片预览已交给系统播放器；尚未复制。");return;}
    if(copyFile(state.editor,result->path)){DestroyWindow(state.editor);}
    else { setStatus(L"视频已保存，但剪贴板正被占用；已打开文件所在目录。");ShellExecuteW(state.editor,L"open",result->path.parent_path().c_str(),nullptr,nullptr,SW_SHOWNORMAL); }
}
void publishOutput(const fs::path &partial,const fs::path &target) {
    // No REPLACE_EXISTING: a collision must preserve both the original and target.
    if(!MoveFileExW(partial.c_str(),target.c_str(),MOVEFILE_WRITE_THROUGH))
        throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法保存完成的视频"};
}
void launchJob(JobKind kind,fs::path target,Plan plan,RECT bounds={},UINT32 width=0,UINT32 height=0,UINT32 frameRate=0) {
    // Resolve policy on the host/core thread; media workers consume values only.
    if(!frameRate)frameRate=static_cast<UINT32>(recordingPlan(2,2).frames_per_second);
    state.kind=kind;state.cancel.store(false);state.stop.store(false);state.progress.store(0);state.closeAfter=false;
    fs::path source=state.source;HWND host=state.host;
    for(HWND control:state.controls)EnableWindow(control,FALSE);
    notify();
    try { state.worker=std::thread([kind,target,plan,bounds,width,height,frameRate,source,host]{
        auto result=std::make_unique<JobResult>();result->kind=kind;result->path=target;
        moojicut::media::OutputFile output(target,kind==JobKind::Recording?
            moojicut::media::OutputKind::Original:moojicut::media::OutputKind::Derived);
        try {
            MediaRuntime runtime;
            if(kind==JobKind::Recording)recordDesktop(output.partial(),bounds,width,height,frameRate,state.stop);
            else exportVideo(source,output.partial(),plan,frameRate,state.cancel,state.progress);
            if(kind!=JobKind::Recording&&state.cancel.load())throw Failure{HRESULT_FROM_WIN32(ERROR_CANCELLED),L"导出已取消"};
            output.publish(publishOutput);result->published=true;
            if(kind==JobKind::Recording){Decoder decoder(target,frameRate);result->width=decoder.width;result->height=decoder.height;result->duration=static_cast<int32_t>(std::min<LONGLONG>(604800000,decoder.duration/10000));}
            result->success=true;
        }catch(const Failure &error){
            // Recording has stop/finalize, not disposable-export cancellation.
            // Even ERROR_CANCELLED from a capture backend must show its retained path.
            result->cancelled=kind!=JobKind::Recording&&error.code==HRESULT_FROM_WIN32(ERROR_CANCELLED);
            result->error=description(error);
        }
        catch(const std::exception &){result->error=L"视频处理失败，请检查磁盘空间与文件权限。";}
        if(kind==JobKind::Recording&&!result->success){
            std::error_code statusError;
            if(fs::is_regular_file(output.retained(),statusError))
                result->error+=L"\n\n录制文件已保留，完整性尚未验证：\n"+output.retained().wstring();
            else if(statusError)
                result->error+=L"\n\n录制文件未被自动清理，请检查输出位置：\n"+output.retained().wstring();
        }
        JobResult *raw=result.release();if(!PostMessageW(host,doneMessage,0,reinterpret_cast<LPARAM>(raw)))delete raw;
    }); } catch (...) { state.kind=JobKind::None;for(HWND control:state.controls)EnableWindow(control,TRUE);notify();throw; }
}
void startExport(bool confirmation) {
    if(state.kind!=JobKind::None||!state.session||!noPendingInputs())return;
    try{
        saveDraft();Plan plan=planFor(state.session);
        fs::path directory=confirmation?applicationDirectory()/L"Exports":state.directory;fs::create_directories(directory);
        fs::path output=directory/((confirmation?L"MoojiCut-":L"preview-")+identifier()+L".mp4");
        launchJob(confirmation?JobKind::Confirm:JobKind::Preview,output,plan);setStatus(L"正在生成视频，可关闭窗口以取消；草稿会保留。");
    }catch(const Failure &error){showFailure(description(error));}catch(const std::exception &){showFailure(L"无法创建视频导出文件。请检查磁盘空间与目录权限。");}
}
int px(HWND window,int value){return MulDiv(value,static_cast<int>(GetDpiForWindow(window)),96);}
HWND control(HWND parent,const wchar_t *klass,const wchar_t *text,DWORD style,int id,int x,int y,int width,int height) {
    HWND result=CreateWindowExW(wcscmp(klass,L"EDIT")==0?WS_EX_CLIENTEDGE:0,klass,text,WS_CHILD|WS_VISIBLE|style,
        px(parent,x),px(parent,y),px(parent,width),px(parent,height),parent,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),state.instance,nullptr);
    SendMessageW(result,WM_SETFONT,reinterpret_cast<WPARAM>(state.font),TRUE);return result;
}
HWND button(HWND parent,const wchar_t *text,int id,int x,int y,int width){HWND item=control(parent,L"BUTTON",text,WS_TABSTOP|BS_PUSHBUTTON,id,x,y,width,27);state.controls.push_back(item);return item;}
void buildEditor(HWND window) {
    state.font=CreateFontW(-MulDiv(10,static_cast<int>(GetDpiForWindow(window)),72),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    control(window,L"STATIC",L"录屏编辑",0,0,20,18,740,22);
    control(window,L"STATIC",L"当前录制主显示器，最高 1920 × 1080 / 15 fps。无音轨（静音录屏）。",0,0,20,48,750,22);
    control(window,L"STATIC",L"填写后点击对应的应用按钮。时间使用原片秒数，编辑可撤销。",0,0,20,76,750,22);
    const wchar_t *labels[]={L"保留范围（秒）",L"删除片段（秒）"};
    for(int row=0;row<2;row++) {
        int y=112+row*44;control(window,L"STATIC",labels[row],0,0,20,y+4,118,22);
        for(int col=0;col<2;col++){int i=row*2+col;state.fields[i]=control(window,L"EDIT",L"0",WS_TABSTOP|ES_RIGHT|ES_AUTOHSCROLL,TrimStart+i,140+col*112,y,94,26);state.controls.push_back(state.fields[i]);}
        control(window,L"STATIC",L"到",0,0,238,y+4,20,22);
    }
    button(window,L"应用裁剪",ApplyTrim,374,112,104);button(window,L"添加删除区间",AddCut,374,156,122);button(window,L"清除删除区间",ClearCuts,508,156,132);
    control(window,L"STATIC",L"裁画面（像素）",0,0,20,204,118,22);
    const wchar_t *cropLabels[]={L"X",L"Y",L"宽",L"高"};
    for(int i=0;i<4;i++){int x=140+i*104;control(window,L"STATIC",cropLabels[i],0,0,x,204,20,22);state.fields[4+i]=control(window,L"EDIT",L"0",WS_TABSTOP|ES_RIGHT|ES_AUTOHSCROLL,CropX+i,x+22,200,70,26);state.controls.push_back(state.fields[4+i]);}
    button(window,L"应用画面",ApplyCrop,566,200,100);button(window,L"完整画面",ResetCrop,678,200,100);
    button(window,L"撤销",Undo,20,248,76);button(window,L"重做",Redo,108,248,76);button(window,L"重置编辑",Reset,196,248,100);
    button(window,L"预览原片",PreviewSource,320,248,112);button(window,L"生成成片预览",PreviewEdited,444,248,138);button(window,L"打开草稿目录",OpenDraft,594,248,140);
    state.summary=control(window,L"STATIC",L"",0,0,20,296,760,24);
    state.status=control(window,L"STATIC",L"",0,0,20,328,760,44);
    control(window,L"BUTTON",L"保留草稿并关闭",WS_TABSTOP|BS_PUSHBUTTON,CloseEditor,20,388,160,30);
    button(window,L"确认并复制视频",Confirm,606,388,172);
    state.pendingCut=false;
    SetTimer(window,1,250,nullptr);
}
LRESULT CALLBACK editorProcedure(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    switch(message){
    case WM_CREATE:buildEditor(window);return 0;
    case WM_COMMAND:if(HIWORD(wp)==EN_CHANGE&&(LOWORD(wp)==CutStart||LOWORD(wp)==CutEnd)){state.pendingCut=true;return 0;}if(HIWORD(wp)==BN_CLICKED){
        int id=LOWORD(wp);int32_t a=0,b=0,c=0,d=0;
        if(id==CloseEditor){mc_recording_close();return 0;}
        if(state.kind!=JobKind::None)return 0;
        switch(id){
        case ApplyTrim:if(number(state.fields[0],a,true)&&number(state.fields[1],b,true))applied(native_video_trim(state.session,a,b));break;
        case AddCut:if(number(state.fields[2],a,true)&&number(state.fields[3],b,true)){int32_t accepted=native_video_cut(state.session,a,b);if(accepted)state.pendingCut=false;applied(accepted);}break;
        case ClearCuts:applied(native_video_clear_cuts(state.session));break;
        case ApplyCrop:if(number(state.fields[4],a,false)&&number(state.fields[5],b,false)&&number(state.fields[6],c,false)&&number(state.fields[7],d,false))applied(native_video_crop(state.session,a,b,c,d));break;
        case ResetCrop:applied(native_video_reset_crop(state.session));break;
        case Undo:applied(native_video_undo(state.session));break;case Redo:applied(native_video_redo(state.session));break;case Reset:applied(native_video_reset(state.session));break;
        case PreviewSource:ShellExecuteW(window,L"open",state.source.c_str(),nullptr,nullptr,SW_SHOWNORMAL);setStatus(L"系统播放器正在预览原片；当前编辑不会改变原片。");break;
        case OpenDraft:ShellExecuteW(window,L"open",state.directory.c_str(),nullptr,nullptr,SW_SHOWNORMAL);break;
        case PreviewEdited:startExport(false);break;case Confirm:startExport(true);break;
        }return 0;
    }break;
    case WM_TIMER:if(state.kind==JobKind::Preview||state.kind==JobKind::Confirm){wchar_t text[120];swprintf_s(text,L"正在生成视频 %d%%… 关闭窗口可以取消并保留草稿。",state.progress.load());setStatus(text);}return 0;
    case WM_CLOSE:mc_recording_close();return 0;
    case WM_DESTROY:KillTimer(window,1);if(state.session)native_video_close(state.session);state.session=0;state.editor=nullptr;state.controls.clear();state.status=nullptr;state.summary=nullptr;if(state.font){DeleteObject(state.font);state.font=nullptr;}notify();return 0;
    }
    return DefWindowProcW(window,message,wp,lp);
}
LRESULT CALLBACK hostProcedure(HWND window,UINT message,WPARAM wp,LPARAM lp){if(message==doneMessage){complete(reinterpret_cast<JobResult *>(lp));return 0;}return DefWindowProcW(window,message,wp,lp);}
bool initialize(HINSTANCE instance,HWND owner) {
    state.instance=instance;state.owner=owner;if(state.host)return true;
    WNDCLASSEXW klass={};klass.cbSize=sizeof(klass);klass.hInstance=instance;klass.lpfnWndProc=hostProcedure;klass.lpszClassName=hostClass;
    if(!RegisterClassExW(&klass)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return false;
    state.host=CreateWindowExW(0,hostClass,L"Mooji Cut recording",0,0,0,0,0,HWND_MESSAGE,nullptr,instance,nullptr);
    klass.lpfnWndProc=editorProcedure;klass.lpszClassName=editorClass;klass.hCursor=LoadCursorW(nullptr,IDC_ARROW);klass.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(IDI_MOOJICUT));klass.hbrBackground=reinterpret_cast<HBRUSH>(COLOR_BTNFACE+1);
    return state.host&&(RegisterClassExW(&klass)||GetLastError()==ERROR_CLASS_ALREADY_EXISTS);
}
void discardUnshownSession() {
    if(!state.editor&&state.session){native_video_close(state.session);state.session=0;}
}
void loadDraftSession(UINT32 width,UINT32 height,int32_t duration) {
    fs::path file=state.directory/L"edit.json";
    if(fs::exists(file)) {
        if(!fs::is_regular_file(file)||fs::file_size(file)==0||fs::file_size(file)>4*1024*1024)
            throw Failure{E_INVALIDARG,L"编辑草稿为空或损坏，已保留原片和草稿文件"};
        std::ifstream saved(file,std::ios::binary);
        if(!saved)throw Failure{E_ACCESSDENIED,L"无法读取编辑草稿，请检查文件权限"};
        std::string bytes((std::istreambuf_iterator<char>(saved)),std::istreambuf_iterator<char>());
        if(saved.bad())throw Failure{E_FAIL,L"读取编辑草稿失败，原文件未修改"};
        moonbit_string_t draft=toString(fromUtf8(bytes));
        state.session=native_video_resume(duration,static_cast<int32_t>(width),static_cast<int32_t>(height),0,draft);moonbit_decref(draft);
        if(!state.session)throw Failure{E_INVALIDARG,L"无法恢复编辑草稿，原文件未修改。\n"+takeString(native_video_error(0))};
    }else{
        state.session=native_video_open(duration,static_cast<int32_t>(width),static_cast<int32_t>(height),0);
        if(!state.session)throw Failure{E_INVALIDARG,takeString(native_video_error(0))};
    }
}
void createEditor(bool visible) {
    saveDraft();
    UINT dpi=GetDpiForSystem();RECT rectangle={0,0,MulDiv(800,static_cast<int>(dpi),96),MulDiv(442,static_cast<int>(dpi),96)};
    DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX;AdjustWindowRectExForDpi(&rectangle,style,FALSE,WS_EX_CONTROLPARENT,dpi);
    state.editor=CreateWindowExW(WS_EX_CONTROLPARENT,editorClass,L"编辑录屏 · Mooji Cut",style,CW_USEDEFAULT,CW_USEDEFAULT,rectangle.right-rectangle.left,rectangle.bottom-rectangle.top,state.owner,nullptr,state.instance,nullptr);
    if(!state.editor)throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法打开录屏编辑器"};
    refresh();if(visible){ShowWindow(state.editor,SW_SHOWNORMAL);SetForegroundWindow(state.editor);}notify();
}
void openEditor(UINT32 width,UINT32 height,int32_t duration) {
    try{loadDraftSession(width,height,duration);createEditor(true);}
    catch(const Failure &error){discardUnshownSession();showFailure(description(error));}
    catch(const std::exception &){discardUnshownSession();showFailure(L"无法打开草稿，请检查文件权限与磁盘空间。");}
}
fs::path latestDraft(const fs::path &root) {
    fs::path latest;fs::file_time_type newest=fs::file_time_type::min();
    if(fs::exists(root))for(const auto &entry:fs::directory_iterator(root)) {
        if(!entry.is_directory())continue;
        fs::path source=entry.path()/L"source.mp4",edit=entry.path()/L"edit.json";
        bool hasSource=fs::is_regular_file(source),hasEdit=fs::is_regular_file(edit);
        if(!hasSource&&!hasEdit)continue;
        auto modified=hasEdit?fs::last_write_time(edit):fs::last_write_time(source);
        if(hasSource)modified=std::max(modified,fs::last_write_time(source));
        if(latest.empty()||modified>newest){latest=entry.path();newest=modified;}
    }
    if(latest.empty())throw Failure{HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND),L"没有可继续编辑的录屏。完成一次录屏后，原片与编辑草稿会保存在本机。"};
    return latest;
}
void restoreDraft(const fs::path &directory,bool visible) {
    fs::path source=directory/L"source.mp4";
    if(!fs::is_regular_file(source))throw Failure{HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND),L"上次录屏的原片 source.mp4 已被移动或删除，无法恢复编辑。\n"+directory.wstring()};
    // A restarted tray process has not initialized Media Foundation yet.
    MediaRuntime runtime;Decoder decoder(source,static_cast<UINT32>(recordingPlan(2,2).frames_per_second));
    std::vector<BYTE> pixels;LONGLONG time=0,length=0;
    if(!decoder.next(pixels,time,length))throw Failure{E_INVALIDARG,L"录屏文件没有可读取的画面，可能已损坏。\n"+source.wstring()};
    if(decoder.duration<10000||decoder.duration/10000>604800000)throw Failure{E_INVALIDARG,L"录屏时长超出支持范围"};
    state.directory=directory;state.source=source;
    loadDraftSession(decoder.width,decoder.height,static_cast<int32_t>(decoder.duration/10000));createEditor(visible);
}
}

extern "C" bool mc_recording_start(HINSTANCE instance,HWND owner) {
    if(mc_recording_busy()){mc_recording_activate();return false;}
    if(!initialize(instance,owner))return false;
    state.prompt=true;notify();
    int choice=MessageBoxW(owner,L"录制主显示器，最高 1920 × 1080 / 15 fps。\n本版不录制系统声音或麦克风（静音录屏）。\n请使用托盘菜单或停止快捷键结束，再编辑并确认。",L"开始录屏 · Mooji Cut",MB_OKCANCEL|MB_ICONINFORMATION);
    state.prompt=false;notify();if(choice!=IDOK)return false;
    try{
        POINT point={0,0};MONITORINFO monitor={};monitor.cbSize=sizeof(monitor);
        if(!GetMonitorInfoW(MonitorFromPoint(point,MONITOR_DEFAULTTOPRIMARY),&monitor))throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法找到主显示器"};
        MCCoreRecordingPlan plan=recordingPlan(monitor.rcMonitor.right-monitor.rcMonitor.left,monitor.rcMonitor.bottom-monitor.rcMonitor.top);
        state.directory=applicationDirectory()/L"Drafts"/identifier();fs::create_directories(state.directory);state.source=state.directory/L"source.mp4";
        launchJob(JobKind::Recording,state.source,Plan{},monitor.rcMonitor,static_cast<UINT32>(plan.width),static_cast<UINT32>(plan.height),static_cast<UINT32>(plan.frames_per_second));return true;
    }catch(const Failure &error){showFailure(description(error));}catch(const std::exception &){showFailure(L"无法开始录屏，请检查磁盘空间和用户目录权限。");}return false;
}
extern "C" bool mc_recording_resume_last(HINSTANCE instance,HWND owner) {
    if(mc_recording_busy()){mc_recording_activate();return false;}
    if(!initialize(instance,owner)){showFailure(L"无法初始化录屏编辑器。");return false;}
    try{restoreDraft(latestDraft(applicationDirectory()/L"Drafts"),true);return true;}
    catch(const Failure &error){discardUnshownSession();showFailure(L"无法继续编辑上次录屏。\n"+description(error));}
    catch(const std::exception &){discardUnshownSession();showFailure(L"无法读取录屏草稿目录，请检查文件权限。原片与草稿未修改。");}
    return false;
}
extern "C" void mc_recording_stop(void){if(state.kind==JobKind::Recording){state.stop.store(true);notify();}}
extern "C" bool mc_recording_busy(void){return state.prompt||state.kind!=JobKind::None||state.editor!=nullptr;}
extern "C" bool mc_recording_recording(void){return state.kind==JobKind::Recording&&!state.stop.load();}
extern "C" bool mc_recording_exporting(void){return state.kind==JobKind::Preview||state.kind==JobKind::Confirm;}
extern "C" void mc_recording_activate(void){if(state.editor){ShowWindow(state.editor,SW_SHOWNORMAL);SetForegroundWindow(state.editor);}}
extern "C" void mc_recording_close(void){
    if(state.kind==JobKind::Recording){mc_recording_stop();return;}
    if(mc_recording_exporting()){
        // Mark cancellation before any UI work: a modal prompt would pump the
        // worker completion message and could publish a video after close.
        state.closeAfter=true;state.cancel.store(true);
        setStatus(L"正在取消并关闭，原片与编辑草稿会保留。");return;
    }
    if(state.editor){try{saveDraft();DestroyWindow(state.editor);}catch(const Failure &error){setStatus(description(error));}}
}
extern "C" bool mc_recording_handle_message(MSG *message){return state.editor&&IsDialogMessageW(state.editor,message)!=FALSE;}

extern "C" int mc_recording_smoke(HINSTANCE instance) {
    int32_t session=0;
    try {
        MCCoreRecordingPlan recording=recordingPlan(320,240),large=recordingPlan(5120,2880),portrait=recordingPlan(1080,1920);
        if(recording.width!=320 || recording.height!=240 || recording.frames_per_second!=15 ||
            large.width!=1920 || large.height!=1080 || portrait.width!=606 || portrait.height!=1080)
            throw Failure{E_FAIL,L"共享录屏参数未保持 Windows 尺寸和帧率"};
        UINT32 frameRate=static_cast<UINT32>(recording.frames_per_second);
        MediaRuntime runtime;fs::path directory=fs::temp_directory_path()/L"moojicut-recording-smoke"/identifier();fs::create_directories(directory);
        fs::path source=directory/L"source.mp4",output=directory/L"edited.mp4";
        {Encoder encoder(source,320,240,frameRate);std::vector<BYTE> pixels(320*240*4);
            for(UINT32 frame=0;frame<60;frame++){
                for(UINT32 y=0;y<240;y++)for(UINT32 x=0;x<320;x++){size_t offset=(static_cast<size_t>(y)*320+x)*4;pixels[offset]=static_cast<BYTE>(y);pixels[offset+1]=static_cast<BYTE>(x);pixels[offset+2]=static_cast<BYTE>(frame*4);pixels[offset+3]=255;}
                LONGLONG now=static_cast<LONGLONG>(frame)*second/frameRate,next=static_cast<LONGLONG>(frame+1)*second/frameRate;encoder.frame(pixels.data(),now,next-now);
            }encoder.finish();}
        // Inject an error after real samples were written. The recording error
        // path must attempt container finalization without masking that error.
        fs::path interrupted=directory/L"interrupted.mp4",retained;
        bool captureFailed=false;
        try {
            moojicut::media::OutputFile file(interrupted,moojicut::media::OutputKind::Original);
            retained=file.partial();Encoder encoder(retained,320,240,frameRate);
            try {
                std::vector<BYTE> frame(320*240*4,127);
                for(UINT32 i=0;i<15;i++)encoder.frame(frame.data(),static_cast<LONGLONG>(i)*second/frameRate,second/frameRate);
                throw Failure{E_ABORT,L"injected capture failure"};
            }catch(...){encoder.finishAfterFailure();encoder.finishAfterFailure();throw;}
        }catch(const Failure &error){captureFailed=error.code==E_ABORT;}
        if(!captureFailed||fs::exists(interrupted)||!fs::is_regular_file(retained))
            throw Failure{E_FAIL,L"录制错误被覆盖或未完成原片丢失"};
        {Decoder recovered(retained,frameRate);std::vector<BYTE> frame;LONGLONG t=0,d=0;
            if(!recovered.next(frame,t,d))throw Failure{E_FAIL,L"故障收尾后原片没有可读取的画面"};}
        // Exercise the exact Windows no-replace publication used by launchJob.
        fs::path collision=directory/L"collision.mp4";{std::ofstream file(collision,std::ios::binary);file<<"existing target";}
        bool renameFailed=false;
        {
            moojicut::media::OutputFile file(collision,moojicut::media::OutputKind::Original);
            retained=file.partial();fs::copy_file(source,retained);
            try{file.publish(publishOutput);}catch(const Failure &){renameFailed=true;}
            if(file.published()||file.retained()!=retained)throw Failure{E_FAIL,L"失败的改名被报告为成功"};
        }
        if(!renameFailed||fs::file_size(retained)!=fs::file_size(source))throw Failure{E_FAIL,L"改名失败后原片丢失"};
        {std::ifstream file(collision,std::ios::binary);std::string text((std::istreambuf_iterator<char>(file)),{});
            if(text!="existing target")throw Failure{E_FAIL,L"改名覆盖了已有文件"};}
        {Decoder recovered(retained,frameRate);std::vector<BYTE> frame;LONGLONG t=0,d=0;
            if(!recovered.next(frame,t,d))throw Failure{E_FAIL,L"改名失败后保留的原片无法读取"};}
        session=native_video_open(4000,320,240,0);
        if(!session||!native_video_trim(session,500,3500)||!native_video_cut(session,1000,1500)||!native_video_cut(session,2000,2500)||!native_video_crop(session,20,30,160,100))throw Failure{E_FAIL,L"MoonBit 视频编辑状态测试失败"};
        Plan plan=planFor(session);std::atomic<bool> cancel{false};std::atomic<int> progress{0};exportVideo(source,output,plan,frameRate,cancel,progress);
        Decoder decoder(output,frameRate);if(decoder.width!=160||decoder.height!=100||std::llabs(decoder.duration-2*second)>second/6||decoder.hasAudio())throw Failure{E_FAIL,L"视频尺寸、时长或无音轨检查失败"};
        ComPtr<IMFMediaType> actual;UINT32 rateNumerator=0,rateDenominator=0;
        check(decoder.reader->GetCurrentMediaType(videoStream,&actual),L"无法读取成片帧率");
        check(MFGetAttributeRatio(actual.Get(),MF_MT_FRAME_RATE,&rateNumerator,&rateDenominator),L"成片没有帧率信息");
        if(!rateDenominator || rateNumerator!=frameRate*rateDenominator)throw Failure{E_FAIL,L"成片帧率与共享录制策略不一致"};
        std::vector<BYTE> pixels;LONGLONG time=0,length=0;if(!decoder.next(pixels,time,length))throw Failure{E_FAIL,L"成片没有画面"};
        const BYTE *center=pixels.data()+(50*160+80)*4;
        if(std::abs(static_cast<int>(center[0])-80)>20||std::abs(static_cast<int>(center[1])-100)>20)throw Failure{E_FAIL,L"裁画面位置或RGB方向不正确"};
        moonbit_string_t snapshot=native_video_snapshot(session);int32_t resumed=native_video_resume(4000,320,240,0,snapshot);moonbit_decref(snapshot);
        if(!resumed||native_video_duration(resumed)!=2000)throw Failure{E_FAIL,L"视频草稿恢复失败"};native_video_close(resumed);
        if(!native_video_undo(session)||!native_video_redo(session))throw Failure{E_FAIL,L"视频撤销重做失败"};
        if(!initialize(instance,nullptr))throw Failure{E_FAIL,L"无法初始化视频编辑窗口"};
        state.directory=directory;state.source=source;state.session=session;session=0;
        state.editor=CreateWindowExW(WS_EX_CONTROLPARENT,editorClass,L"Mooji Cut video smoke",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU,
            0,0,820,480,nullptr,nullptr,instance,nullptr);
        if(!state.editor)throw Failure{E_FAIL,L"无法创建视频编辑测试窗口"};
        refresh();saveDraft();
        SetWindowTextW(state.fields[0],L"0.750");
        if(noPendingInputs())throw Failure{E_FAIL,L"未应用的裁剪输入被忽略"};
        refresh();SetWindowTextW(state.fields[2],L"0.200");SetWindowTextW(state.fields[3],L"0.300");
        if(noPendingInputs())throw Failure{E_FAIL,L"未添加的删除区间被忽略"};
        SetWindowTextW(state.fields[2],L"0");SetWindowTextW(state.fields[3],L"0");
        if(!noPendingInputs())throw Failure{E_FAIL,L"有效编辑状态无法确认"};
        fs::path cancelled=directory/L"cancelled.mp4";fs::copy_file(output,cancelled);
        DWORD clipboardSequence=GetClipboardSequenceNumber();
        state.kind=JobKind::Confirm;state.cancel.store(false);state.closeAfter=false;
        mc_recording_close();
        auto completed=std::make_unique<JobResult>();completed->kind=JobKind::Confirm;completed->success=true;completed->published=true;completed->path=cancelled;
        SendMessageW(state.host,doneMessage,0,reinterpret_cast<LPARAM>(completed.release()));
        if(mc_recording_busy()||fs::exists(cancelled)||GetClipboardSequenceNumber()!=clipboardSequence)
            throw Failure{E_FAIL,L"关闭后的完成回调仍然发布了视频"};
        // A late cancel after failed publication must not delete a foreign path.
        auto failed=std::make_unique<JobResult>();failed->kind=JobKind::Confirm;failed->path=source;
        SendMessageW(state.host,doneMessage,0,reinterpret_cast<LPARAM>(failed.release()));
        if(!fs::is_regular_file(source))throw Failure{E_FAIL,L"取消失败导出误删了未发布的文件"};
        wchar_t ci[16];DWORD ciLength=GetEnvironmentVariableW(L"CI",ci,16);
        if(ciLength&&ciLength<16&&_wcsicmp(ci,L"true")==0){
            HWND clipboardOwner=CreateWindowExW(0,L"STATIC",L"Mooji Cut clipboard test",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,nullptr);
            if(!clipboardOwner)throw Failure{E_FAIL,L"无法创建CI剪贴板所有者"};
            bool copied=copyFile(clipboardOwner,output)&&IsClipboardFormatAvailable(CF_HDROP);
            DestroyWindow(clipboardOwner);if(!copied)throw Failure{E_FAIL,L"CI文件剪贴板检查失败"};
        }
        else std::printf("Clipboard test skipped outside CI.\n");
        std::printf("Windows Media Foundation recording/edit/export smoke passed.\n");return 0;
    }catch(const Failure &error){if(session)native_video_close(session);std::fprintf(stderr,"Recording smoke failed: %s\n",utf8(description(error)).c_str());}
    catch(const std::exception &){if(session)native_video_close(session);std::fprintf(stderr,"Recording smoke failed: native exception.\n");}
    if(state.editor)DestroyWindow(state.editor);
    else if(state.session){native_video_close(state.session);state.session=0;}
    state.kind=JobKind::None;
    return 1;
}

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
#include "bindings/c/recording_plan.h"
#include "bindings/c/recording_flow.h"
#include "plugins/feature/select/windows/surface.h"
#include <commctrl.h>
#include <windowsx.h>
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

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;
namespace {
constexpr LONGLONG second = 10000000;
constexpr DWORD videoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD audioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr DWORD allStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD mediaSource = static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);
constexpr UINT doneMessage = WM_APP + 0x62;
constexpr UINT startedMessage = WM_APP + 0x63;
constexpr UINT_PTR flowTimer = 2;
constexpr wchar_t flowClass[] = L"MoojiCut.Recording.Controls";
constexpr wchar_t hostClass[] = L"MoojiCut.Recording.WorkerHost";
struct Failure { HRESULT code; std::wstring stage; };
void check(HRESULT hr, const wchar_t *stage) { if (FAILED(hr)) throw Failure{hr, stage}; }
MCCoreRecordingPlan recordingPlan(int32_t width, int32_t height) {
    MCCoreRecordingPlan plan=mc_core_recording_plan(MC_RECORDING_WINDOWS,width,height,0);
    if(plan.width<=0 || plan.height<=0 || plan.frames_per_second<=0 || plan.system_audio || plan.microphone || plan.countdown_seconds!=3)
        throw Failure{E_INVALIDARG,L"无法规划所选区域的录制参数"};
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
std::string utf8(const std::wstring &value) {
    if (value.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!size) throw Failure{HRESULT_FROM_WIN32(GetLastError()), L"无法编码草稿"};
    std::string result(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr); return result;
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
void captureDesktopFrame(DesktopSurface &surface,HDC source,RECT bounds,UINT32 width,UINT32 height) {
    if(!StretchBlt(surface.memory,0,0,static_cast<int>(width),static_cast<int>(height),source,bounds.left,bounds.top,
        bounds.right-bounds.left,bounds.bottom-bounds.top,SRCCOPY|CAPTUREBLT))
        throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法读取所选区域；安全桌面或受保护内容不可录制"};
}
void recordDesktop(const fs::path &target, RECT bounds, UINT32 width, UINT32 height, UINT32 frameRate,
    std::atomic<bool> &stop,HWND host,int32_t flow) {
    Encoder encoder(target,width,height,frameRate);
    try {
        DesktopSurface surface(width,height);
        // Let the countdown window disappear before the first frame.
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        std::vector<BYTE> pending(static_cast<size_t>(width)*height*4);
        LARGE_INTEGER frequency,origin,now; QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&origin);
        LONGLONG last=0; bool haveFrame=false;
        auto next=std::chrono::steady_clock::now();
        do {
            captureDesktopFrame(surface,surface.screen,bounds,width,height);
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
            if(!haveFrame) { origin=now; timestamp=0; PostMessageW(host,startedMessage,static_cast<WPARAM>(flow),0); }
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

enum class JobKind { None, Recording };
struct JobResult { int32_t flow=0; JobKind kind; bool success=false; std::wstring error; fs::path path; UINT32 width=0,height=0; int32_t duration=0; };
struct RecordingState {
    HINSTANCE instance=nullptr; HWND owner=nullptr,host=nullptr;
    std::thread worker; std::atomic<bool> stop{false};
    JobKind kind=JobKind::None; fs::path directory,source;
    MCRecordingCompleted completed=nullptr; void *completedContext=nullptr;
    int32_t flow=0; HWND selection=nullptr,panel=nullptr,action=nullptr,tooltip=nullptr;
    RECT desktopBounds={},region={},workArea={}; double panelFrame[14]={},scale=1,logicalWidth=0,logicalHeight=0;
    std::unique_ptr<DesktopSurface> frozen,dimmed;
    bool updatingPanel=false,smoke=false,smokeRealDesktop=false; double smokeNow=1000;
    fs::path smokeDirectory;
    ~RecordingState(){stop.store(true);if(worker.joinable())worker.join();}
} state;
void notify() { if(state.owner) PostMessageW(state.owner,MOOJICUT_RECORDING_STATE_CHANGED,0,0); }
void showFailure(const std::wstring &message) {
    if(state.smoke) { std::fprintf(stderr,"Recording smoke failure: %s\n",utf8(message).c_str()); return; }
    MessageBoxW(state.owner,message.c_str(),L"Mooji Cut",MB_OK|MB_ICONWARNING);
}
double flowNow() { return state.smoke?state.smokeNow:static_cast<double>(GetTickCount64()); }
void dispatchFlow(int32_t event);
void closeFlowPanel();
void updateFlowPanel();
void releaseFlow();
void beginSelection();
LRESULT CALLBACK flowProcedure(HWND window,UINT message,WPARAM wp,LPARAM lp);
void complete(JobResult *raw) {
    std::unique_ptr<JobResult> result(raw);
    // A delayed message must never join or mutate another recording session.
    if(result->kind==JobKind::Recording && result->flow!=state.flow)return;
    if(state.worker.joinable())state.worker.join();
    if(result->kind==JobKind::Recording && state.flow) {
        // The worker has finalized/closed MF, decoder and desktop resources.
        int32_t effect=recording_flow_event(state.flow,result->success?MC_RECORDING_COMPLETE:MC_RECORDING_FAIL,flowNow());
        if(result->success && effect!=MC_RECORDING_DELIVER_MEDIA) {
            result->success=false;result->error=L"录屏完成时会话已失效，原片保留在：\n"+result->path.wstring();
        }
        releaseFlow();
    }
    state.kind=JobKind::None;notify();
    if(!result->success) { showFailure(result->error); return; }
    if(!state.completed || !state.completed(state.completedContext,result->path.c_str()))
        showFailure(L"无法打开编辑窗口，完整原片已保留：\n"+result->path.wstring());
}
void publishOutput(const fs::path &partial,const fs::path &target) {
    // No REPLACE_EXISTING: a collision must preserve both the original and target.
    if(!MoveFileExW(partial.c_str(),target.c_str(),MOVEFILE_WRITE_THROUGH))
        throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法保存完成的视频"};
}
void launchJob(JobKind kind,fs::path target,RECT bounds,UINT32 width,UINT32 height,UINT32 frameRate) {
    // Resolve policy on the host/core thread; media workers consume values only.
    if(!frameRate)frameRate=static_cast<UINT32>(recordingPlan(2,2).frames_per_second);
    state.kind=kind;state.stop.store(false);
    HWND host=state.host;int32_t flow=state.flow;
    notify();
    try { state.worker=std::thread([kind,target,bounds,width,height,frameRate,host,flow]{
        auto result=std::make_unique<JobResult>();result->flow=flow;result->kind=kind;result->path=target;
        moojicut::media::OutputFile output(target,moojicut::media::OutputKind::Original);
        try {
            MediaRuntime runtime;
            recordDesktop(output.partial(),bounds,width,height,frameRate,state.stop,host,flow);
            output.publish(publishOutput);
            if(kind==JobKind::Recording){Decoder decoder(target,frameRate);result->width=decoder.width;result->height=decoder.height;result->duration=static_cast<int32_t>(std::min<LONGLONG>(604800000,decoder.duration/10000));}
            result->success=true;
        }catch(const Failure &error){
            // Recording has stop/finalize, not disposable-export cancellation.
            // Even ERROR_CANCELLED from a capture backend must show its retained path.
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
    }); } catch (...) { state.kind=JobKind::None;notify();throw; }
}
LRESULT CALLBACK hostProcedure(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    if(message==doneMessage){complete(reinterpret_cast<JobResult *>(lp));return 0;}
    if(message==startedMessage) {
        if(state.flow && static_cast<int32_t>(wp)==state.flow)dispatchFlow(MC_RECORDING_STARTED);
        return 0;
    }
    if(message==WM_TIMER && wp==flowTimer){if(state.flow)dispatchFlow(MC_RECORDING_TICK);return 0;}
    return DefWindowProcW(window,message,wp,lp);
}
bool initialize(HINSTANCE instance,HWND owner) {
    state.instance=instance;state.owner=owner;if(state.host)return true;
    WNDCLASSEXW klass={};klass.cbSize=sizeof(klass);klass.hInstance=instance;klass.lpfnWndProc=hostProcedure;klass.lpszClassName=hostClass;
    if(!RegisterClassExW(&klass)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return false;
    state.host=CreateWindowExW(0,hostClass,L"Mooji Cut recording",0,0,0,0,0,HWND_MESSAGE,nullptr,instance,nullptr);
    if(!state.host)return false;
    klass.lpfnWndProc=flowProcedure;klass.lpszClassName=flowClass;klass.hbrBackground=nullptr;
    klass.hCursor=LoadCursorW(nullptr,IDC_ARROW);klass.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(IDI_MOOJICUT));
    return RegisterClassExW(&klass)||GetLastError()==ERROR_CLASS_ALREADY_EXISTS;
}
void closeFlowPanel() {
    HWND panel=state.panel;state.panel=nullptr;state.action=nullptr;state.tooltip=nullptr;
    if(panel)DestroyWindow(panel);
}
void clearSelection() {
    HWND selection=state.selection;state.selection=nullptr;
    if(selection)mc_selection_surface_dismiss(selection);
    state.frozen.reset();state.dimmed.reset();
}
void releaseFlow() {
    clearSelection();closeFlowPanel();KillTimer(state.host,flowTimer);
    if(state.flow && recording_flow_close(state.flow))state.flow=0;
    notify();
}
bool excludesCapture(HWND window) {
    // On older Windows the same flag behaves as WDA_MONITOR (a black box).
    // Keep live controls hidden there; the tray/registered stop key remains usable.
    // app.manifest declares Windows 10 compatibility for this documented check.
    static const bool supported=[] {
        OSVERSIONINFOEXW info={};info.dwOSVersionInfoSize=sizeof(info);
        info.dwMajorVersion=10;info.dwBuildNumber=19041;DWORDLONG condition=0;
        const DWORD fields[]={VER_MAJORVERSION,VER_MINORVERSION,VER_SERVICEPACKMAJOR,VER_SERVICEPACKMINOR,VER_BUILDNUMBER};
        DWORD mask=0;for(DWORD field:fields){mask|=field;condition=VerSetConditionMask(condition,field,VER_GREATER_EQUAL);}
        return VerifyVersionInfoW(&info,mask,condition)!=FALSE;
    }();
    return supported && SetWindowDisplayAffinity(window,0x00000011)!=FALSE;
}
RECT panelRect(int field) {
    int x=static_cast<int>(std::lround((state.panelFrame[field]-state.panelFrame[0])*state.scale));
    int y=static_cast<int>(std::lround((state.panelFrame[field+1]-state.panelFrame[1])*state.scale));
    return RECT{x,y,x+static_cast<LONG>(std::lround(state.panelFrame[field+2]*state.scale)),
        y+static_cast<LONG>(std::lround(state.panelFrame[field+3]*state.scale))};
}
void updateFlowPanel() {
    if(!state.flow || !state.panel || state.updatingPanel)return;
    state.updatingPanel=true;
    struct Reset { ~Reset(){state.updatingPanel=false;} } reset;
    int32_t phase=recording_flow_value(state.flow,MC_RECORDING_PHASE);
    state.scale=static_cast<double>(GetDpiForWindow(state.panel))/96;
    if(state.scale<=0)state.scale=1;
    state.logicalWidth=(state.workArea.right-state.workArea.left)/state.scale;
    state.logicalHeight=(state.workArea.bottom-state.workArea.top)/state.scale;
    double *frame=recording_ui_frame(state.flow,state.logicalWidth,state.logicalHeight);
    std::copy(frame,frame+14,state.panelFrame);moonbit_decref(frame);
    if(state.panelFrame[2]<=0 || state.panelFrame[3]<=0){ShowWindow(state.panel,SW_HIDE);return;}
    SetWindowPos(state.panel,HWND_TOPMOST,
        state.workArea.left+static_cast<int>(std::lround(state.panelFrame[0]*state.scale)),
        state.workArea.top+static_cast<int>(std::lround(state.panelFrame[1]*state.scale)),
        static_cast<int>(std::lround(state.panelFrame[2]*state.scale)),
        static_cast<int>(std::lround(state.panelFrame[3]*state.scale)),SWP_NOACTIVATE);
    RECT button=panelRect(8);
    MoveWindow(state.action,button.left,button.top,button.right-button.left,button.bottom-button.top,TRUE);
    int event=static_cast<int>(state.panelFrame[13]);
    EnableWindow(state.action,event!=0);
    ShowWindow(state.action,event?SW_SHOW:SW_HIDE);
    const wchar_t *name=event==MC_RECORDING_CANCEL?L"取消录制（Esc）":L"停止录制（Esc）";
    SetWindowTextW(state.action,name);
    if(state.tooltip){TOOLINFOW tool={};tool.cbSize=sizeof(tool);tool.hwnd=state.panel;
        tool.uFlags=TTF_IDISHWND|TTF_SUBCLASS;tool.uId=reinterpret_cast<UINT_PTR>(state.action);
        tool.lpszText=const_cast<wchar_t *>(name);SendMessageW(state.tooltip,TTM_UPDATETIPTEXTW,0,reinterpret_cast<LPARAM>(&tool));}
    std::wstring text=takeString(recording_ui_text(state.flow));
    SetWindowTextW(state.panel,text.c_str());InvalidateRect(state.panel,nullptr,FALSE);
    bool visible=phase==MC_RECORDING_COUNTDOWN || ((phase==MC_RECORDING_ACTIVE||phase==MC_RECORDING_STOPPING)&&excludesCapture(state.panel));
    // Tooltips are separate top-level windows: excluding their owner alone
    // does not exclude the tooltip. If exclusion fails, retain button names
    // for accessibility but disable/pop the visual tooltip while capturing.
    if(state.tooltip){
        bool tips=phase==MC_RECORDING_COUNTDOWN || (visible&&excludesCapture(state.tooltip));
        SendMessageW(state.tooltip,TTM_ACTIVATE,tips&&!state.smoke,0);
        if(!tips||state.smoke)SendMessageW(state.tooltip,TTM_POP,0,0);
    }
    // Never show a STARTING panel in the first frame before exclusion applies.
    ShowWindow(state.panel,visible&&!state.smoke?SW_SHOWNOACTIVATE:SW_HIDE);
}
void createFlowPanel() {
    MONITORINFO monitor={};monitor.cbSize=sizeof(monitor);
    if(!GetMonitorInfoW(MonitorFromRect(&state.region,MONITOR_DEFAULTTONEAREST),&monitor))
        throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法定位录屏倒计时"};
    state.workArea=monitor.rcWork;
    state.panel=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_CONTROLPARENT,flowClass,L"Mooji Cut",
        WS_POPUP|WS_CLIPCHILDREN,monitor.rcWork.left,monitor.rcWork.top,200,176,state.owner,nullptr,state.instance,nullptr);
    if(!state.panel)throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法显示录屏倒计时"};
    state.action=CreateWindowExW(0,L"BUTTON",L"取消录制（Esc）",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_OWNERDRAW,
        0,0,1,1,state.panel,reinterpret_cast<HMENU>(static_cast<INT_PTR>(9300)),state.instance,nullptr);
    if(!state.action)throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法创建录屏取消按钮"};
    state.tooltip=CreateWindowExW(WS_EX_TOPMOST,TOOLTIPS_CLASSW,nullptr,WS_POPUP|TTS_ALWAYSTIP,
        CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,state.panel,nullptr,state.instance,nullptr);
    if(state.tooltip){TOOLINFOW tool={};tool.cbSize=sizeof(tool);tool.hwnd=state.panel;tool.uFlags=TTF_IDISHWND|TTF_SUBCLASS;
        tool.uId=reinterpret_cast<UINT_PTR>(state.action);tool.lpszText=const_cast<wchar_t *>(L"取消录制（Esc）");
        SendMessageW(state.tooltip,TTM_ADDTOOLW,0,reinterpret_cast<LPARAM>(&tool));}
    updateFlowPanel();
    if(!state.smoke){SetForegroundWindow(state.panel);SetFocus(state.action);}
}
void selectionFinished(void *context,BOOL accepted,RECT rect) {
    int32_t flow=static_cast<int32_t>(reinterpret_cast<INT_PTR>(context));
    if(!state.flow || state.flow!=flow)return;
    state.selection=nullptr;
    if(!accepted){dispatchFlow(MC_RECORDING_CANCEL);return;}
    state.region={state.desktopBounds.left+rect.left,state.desktopBounds.top+rect.top,
        state.desktopBounds.left+rect.right,state.desktopBounds.top+rect.bottom};
    state.frozen.reset();state.dimmed.reset();
    dispatchFlow(MC_RECORDING_SELECTED);
}
void beginSelection() {
    if(state.smoke&&!state.smokeRealDesktop)state.desktopBounds={-240,80,400,560};
    else if(!mc_selection_desktop_bounds(&state.desktopBounds))throw Failure{E_FAIL,L"无法枚举桌面显示器"};
    LONGLONG width=static_cast<LONGLONG>(state.desktopBounds.right)-state.desktopBounds.left;
    LONGLONG height=static_cast<LONGLONG>(state.desktopBounds.bottom)-state.desktopBounds.top;
    if(width<2||height<2||width>32768||height>32768||width*height>64000000)
        throw Failure{E_INVALIDARG,L"桌面尺寸超出可框选范围"};
    state.frozen=std::make_unique<DesktopSurface>(static_cast<UINT32>(width),static_cast<UINT32>(height));
    state.dimmed=std::make_unique<DesktopSurface>(static_cast<UINT32>(width),static_cast<UINT32>(height));
    if(state.smoke&&!state.smokeRealDesktop){for(LONGLONG i=0;i<width*height;i++){state.frozen->pixels[i*4]=80;state.frozen->pixels[i*4+1]=160;state.frozen->pixels[i*4+2]=220;state.frozen->pixels[i*4+3]=0;}}
    else if(!BitBlt(state.frozen->memory,0,0,static_cast<int>(width),static_cast<int>(height),state.frozen->screen,
        state.desktopBounds.left,state.desktopBounds.top,SRCCOPY|CAPTUREBLT))
        throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法读取桌面以选择录屏区域"};
    GdiFlush();
    for(LONGLONG i=0;i<width*height*4;i+=4){
        for(int channel=0;channel<3;channel++)
            state.dimmed->pixels[i+channel]=static_cast<BYTE>(state.frozen->pixels[i+channel]*3/5);
        state.dimmed->pixels[i+3]=0;
    }
    MCSelectionSurfaceOptions options={};options.desktop_bounds=state.desktopBounds;options.desktop=state.frozen->memory;
    options.dimmed=state.dimmed->memory;options.hidden=state.smoke;
    options.context=reinterpret_cast<void *>(static_cast<INT_PTR>(state.flow));options.finished=selectionFinished;
    state.selection=mc_selection_surface_open(state.instance,state.owner,&options);
    if(!state.selection)throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法打开录屏框选界面"};
    if(!state.smoke)mc_selection_surface_activate(state.selection);
}
void dispatchFlow(int32_t event) {
    if(!state.flow)return;
    int32_t previousPhase=recording_flow_value(state.flow,MC_RECORDING_PHASE);
    int32_t effect=recording_flow_event(state.flow,event,flowNow());
    if(effect==MC_RECORDING_REJECTED)return;
    try {
        if(effect==MC_RECORDING_REQUEST_SOURCE)beginSelection();
        else if(effect==MC_RECORDING_RELEASE_SOURCE){
            clearSelection();closeFlowPanel();KillTimer(state.host,flowTimer);
            recording_flow_event(state.flow,MC_RECORDING_COMPLETE,flowNow());releaseFlow();return;
        } else if(effect==MC_RECORDING_STOP_MEDIA){state.stop.store(true);}
        else if(effect==MC_RECORDING_START_MEDIA){
            RECT current={};
            if(!mc_selection_desktop_bounds(&current)||!EqualRect(&current,&state.desktopBounds))
                throw Failure{E_FAIL,L"显示器布局已改变，请重新选择录屏区域"};
            if(!MonitorFromRect(&state.region,MONITOR_DEFAULTTONULL))throw Failure{E_FAIL,L"所选区域已不在显示器上"};
            if(state.tooltip){SendMessageW(state.tooltip,TTM_ACTIVATE,FALSE,0);SendMessageW(state.tooltip,TTM_POP,0,0);}
            ShowWindow(state.panel,SW_HIDE);GdiFlush();
            MCCoreRecordingPlan plan=recordingPlan(state.region.right-state.region.left,state.region.bottom-state.region.top);
            // Native smoke must never create drafts in the user's data folder.
            if(state.smoke&&state.smokeDirectory.empty())throw Failure{E_FAIL,L"录屏测试未配置隔离输出目录"};
            state.directory=(state.smoke?state.smokeDirectory:applicationDirectory()/L"Drafts")/identifier();
            fs::create_directories(state.directory);state.source=state.directory/L"source.mp4";
            launchJob(JobKind::Recording,state.source,state.region,static_cast<UINT32>(plan.width),
                static_cast<UINT32>(plan.height),static_cast<UINT32>(plan.frames_per_second));
        }
        if(event==MC_RECORDING_SELECTED && state.flow){
            createFlowPanel();
            if(!SetTimer(state.host,flowTimer,50,nullptr))throw Failure{HRESULT_FROM_WIN32(GetLastError()),L"无法启动录屏倒计时"};
        }
        updateFlowPanel();
        // Countdown/timer ticks repaint locally; shell tray state only changes
        // at phase boundaries, not twenty times per second during recording.
        if(recording_flow_value(state.flow,MC_RECORDING_PHASE)!=previousPhase)notify();
    } catch(const Failure &error) {
        if(state.kind==JobKind::Recording){recording_flow_event(state.flow,MC_RECORDING_STOP,flowNow());state.stop.store(true);}
        else {clearSelection();closeFlowPanel();recording_flow_event(state.flow,MC_RECORDING_FAIL,flowNow());releaseFlow();}
        showFailure(description(error));
    } catch(const std::exception &) {
        if(state.kind==JobKind::Recording){recording_flow_event(state.flow,MC_RECORDING_STOP,flowNow());state.stop.store(true);}
        else {clearSelection();closeFlowPanel();recording_flow_event(state.flow,MC_RECORDING_FAIL,flowNow());releaseFlow();}
        showFailure(L"无法开始录屏，请检查磁盘空间和用户目录权限。");
    }
}
LRESULT CALLBACK flowProcedure(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    switch(message){
    case WM_ERASEBKGND:return 1;
    case WM_PAINT:{
        PAINTSTRUCT paint;HDC dc=BeginPaint(window,&paint);RECT client;GetClientRect(window,&client);
        HBRUSH background=CreateSolidBrush(RGB(26,26,28));FillRect(dc,&client,background);DeleteObject(background);
        RECT label=panelRect(4);HFONT font=CreateFontW(-static_cast<int>(std::lround(state.panelFrame[12]*state.scale)),0,0,0,
            FW_MEDIUM,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
        HGDIOBJ old=SelectObject(dc,font);SetBkMode(dc,TRANSPARENT);SetTextColor(dc,RGB(245,245,245));
        std::wstring text=state.flow?takeString(recording_ui_text(state.flow)):L"";
        DrawTextW(dc,text.c_str(),static_cast<int>(text.size()),&label,DT_CENTER|DT_VCENTER|DT_SINGLELINE);
        SelectObject(dc,old);DeleteObject(font);EndPaint(window,&paint);return 0;
    }
    case WM_DRAWITEM:{
        auto item=reinterpret_cast<DRAWITEMSTRUCT *>(lp);if(item->CtlID!=9300)break;
        HBRUSH fill=CreateSolidBrush((item->itemState&ODS_SELECTED)?RGB(72,72,76):RGB(48,48,52));FillRect(item->hDC,&item->rcItem,fill);DeleteObject(fill);
        int cx=(item->rcItem.left+item->rcItem.right)/2,cy=(item->rcItem.top+item->rcItem.bottom)/2;
        int radius=std::max(4,static_cast<int>(std::lround(6*state.scale)));
        HPEN pen=CreatePen(PS_SOLID,std::max(1,static_cast<int>(std::lround(2*state.scale))),RGB(245,245,245));HGDIOBJ old=SelectObject(item->hDC,pen);
        if(static_cast<int>(state.panelFrame[13])==MC_RECORDING_CANCEL){MoveToEx(item->hDC,cx-radius,cy-radius,nullptr);LineTo(item->hDC,cx+radius,cy+radius);MoveToEx(item->hDC,cx+radius,cy-radius,nullptr);LineTo(item->hDC,cx-radius,cy+radius);}
        else {RECT square={cx-radius,cy-radius,cx+radius,cy+radius};HBRUSH white=CreateSolidBrush(RGB(245,245,245));FillRect(item->hDC,&square,white);DeleteObject(white);}
        SelectObject(item->hDC,old);DeleteObject(pen);
        if(item->itemState&ODS_FOCUS){RECT focus=item->rcItem;InflateRect(&focus,-3,-3);DrawFocusRect(item->hDC,&focus);}return TRUE;
    }
    case WM_COMMAND:
        if(LOWORD(wp)==9300 && HIWORD(wp)==BN_CLICKED && state.flow){
            int event=recording_ui_hit(state.flow,state.panelFrame[8]+state.panelFrame[10]/2,
                state.panelFrame[9]+state.panelFrame[11]/2,state.logicalWidth,state.logicalHeight);
            if(event)dispatchFlow(event);return 0;
        }break;
    case WM_KEYDOWN:if(wp==VK_ESCAPE){dispatchFlow(MC_RECORDING_STOP);return 0;}break;
    case WM_CLOSE:dispatchFlow(MC_RECORDING_STOP);return 0;
    case WM_DISPLAYCHANGE:dispatchFlow(MC_RECORDING_STOP);return 0;
    case WM_DPICHANGED:updateFlowPanel();return 0;
    case WM_NCDESTROY:if(state.panel==window){state.panel=nullptr;state.action=nullptr;state.tooltip=nullptr;}break;
    }
    return DefWindowProcW(window,message,wp,lp);
}
fs::path latestDraft(const fs::path &root) {
    fs::path latest;fs::file_time_type newest=fs::file_time_type::min();
    if(fs::exists(root))for(const auto &entry:fs::directory_iterator(root)) {
        if(!entry.is_directory())continue;
        fs::path source=entry.path()/L"source.mp4",edit=entry.path()/L"edit-v2.json";
        if(!fs::exists(edit))edit=entry.path()/L"edit.json";
        bool hasSource=fs::is_regular_file(source),hasEdit=fs::is_regular_file(edit);
        if(!hasSource&&!hasEdit)continue;
        auto modified=hasEdit?fs::last_write_time(edit):fs::last_write_time(source);
        if(hasSource)modified=std::max(modified,fs::last_write_time(source));
        if(latest.empty()||modified>newest){latest=entry.path();newest=modified;}
    }
    if(latest.empty())throw Failure{HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND),L"没有可继续编辑的录屏。完成一次录屏后，原片与编辑草稿会保存在本机。"};
    return latest;
}
void restoreDraft(const fs::path &directory) {
    fs::path source=directory/L"source.mp4";
    if(!fs::is_regular_file(source))throw Failure{HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND),L"上次录屏的原片 source.mp4 已被移动或删除，无法恢复编辑。\n"+directory.wstring()};
    if(!state.completed || !state.completed(state.completedContext,source.c_str()))
        throw Failure{E_FAIL,L"无法打开编辑窗口，原片和编辑草稿仍保留在：\n"+directory.wstring()};
}
}

extern "C" void mc_recording_set_completed_callback(MCRecordingCompleted callback,void *context) {
    state.completed=callback;state.completedContext=context;
}
extern "C" bool mc_recording_start(HINSTANCE instance,HWND owner) {
    if(mc_recording_busy()){mc_recording_activate();return false;}
    if(!initialize(instance,owner)){showFailure(L"无法初始化录屏界面。");return false;}
    state.flow=recording_flow_open();
    if(!state.flow){showFailure(L"无法创建录屏会话。");return false;}
    dispatchFlow(MC_RECORDING_BEGIN);
    return state.flow!=0;
}
extern "C" bool mc_recording_resume_last(HINSTANCE instance,HWND owner) {
    if(mc_recording_busy()){mc_recording_activate();return false;}
    if(!initialize(instance,owner)){showFailure(L"无法初始化录屏编辑器。");return false;}
    try{restoreDraft(latestDraft(applicationDirectory()/L"Drafts"));return true;}
    catch(const Failure &error){showFailure(L"无法继续编辑上次录屏。\n"+description(error));}
    catch(const std::exception &){showFailure(L"无法读取录屏草稿目录，请检查文件权限。原片与草稿未修改。");}
    return false;
}
extern "C" void mc_recording_stop(void) {
    if(state.flow)dispatchFlow(MC_RECORDING_STOP);
    else if(state.kind==JobKind::Recording){state.stop.store(true);notify();}
}
extern "C" bool mc_recording_busy(void){return state.flow!=0||state.kind!=JobKind::None;}
extern "C" bool mc_recording_preparing(void) {
    if(!state.flow)return false;
    int32_t phase=recording_flow_value(state.flow,MC_RECORDING_PHASE);
    return phase==MC_RECORDING_SELECTING||phase==MC_RECORDING_COUNTDOWN||phase==MC_RECORDING_STARTING;
}
extern "C" bool mc_recording_recording(void){return state.flow && recording_flow_value(state.flow,MC_RECORDING_PHASE)==MC_RECORDING_ACTIVE;}
extern "C" void mc_recording_activate(void) {
    if(state.selection){mc_selection_surface_activate(state.selection);return;}
    HWND window=state.panel;
    if(window && IsWindowVisible(window)){ShowWindow(window,SW_SHOWNORMAL);SetForegroundWindow(window);}
}
extern "C" void mc_recording_close(void){
    if(state.flow){dispatchFlow(MC_RECORDING_STOP);return;}
    if(state.kind==JobKind::Recording){mc_recording_stop();return;}

}
extern "C" bool mc_recording_handle_message(MSG *message) {
    if(state.panel && (message->hwnd==state.panel||IsChild(state.panel,message->hwnd))) {
        if(message->message==WM_KEYDOWN&&message->wParam==VK_ESCAPE){dispatchFlow(MC_RECORDING_STOP);return true;}
        if(IsDialogMessageW(state.panel,message))return true;
    }
    return false;
}

void selectionFlowSmoke(HINSTANCE instance) {
    state.smoke=true;state.smokeNow=1000;
    if(!mc_recording_start(instance,nullptr)||!state.selection||!mc_recording_preparing())
        throw Failure{E_FAIL,L"录屏真实入口未出现共用选区"};
    int32_t first=state.flow;HWND selection=state.selection;
    SendMessageW(selection,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(330,220));
    SendMessageW(selection,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(10,20));
    SendMessageW(selection,WM_LBUTTONUP,0,MAKELPARAM(10,20));
    RECT expected={-230,100,90,300};
    if(state.selection||!state.panel||!EqualRect(&state.region,&expected)||state.frozen||state.dimmed||
        recording_flow_value(state.flow,MC_RECORDING_PHASE)!=MC_RECORDING_COUNTDOWN||
        recording_flow_value(state.flow,MC_RECORDING_REMAINING)!=3||state.kind!=JobKind::None)
        throw Failure{E_FAIL,L"拖拽选区没有进入倒计时，或负坐标转换/资源释放错误"};
    MCCoreRecordingPlan plan=recordingPlan(state.region.right-state.region.left,state.region.bottom-state.region.top);
    if(plan.width!=320||plan.height!=200)throw Failure{E_FAIL,L"区域录制错误使用了整屏尺寸"};
    state.smokeNow=2999;SendMessageW(state.host,WM_TIMER,flowTimer,0);
    if(recording_flow_value(state.flow,MC_RECORDING_REMAINING)!=2||state.kind!=JobKind::None)
        throw Failure{E_FAIL,L"共享倒计时未消费单调时钟"};
    state.smokeNow=3999;SendMessageW(state.host,WM_TIMER,flowTimer,0);
    if(recording_flow_value(state.flow,MC_RECORDING_REMAINING)!=1||state.kind!=JobKind::None)
        throw Failure{E_FAIL,L"倒计时未完成就开始了采集"};
    SendMessageW(state.panel,WM_KEYDOWN,VK_ESCAPE,0);
    if(mc_recording_busy()||state.flow||state.panel||state.selection||state.kind!=JobKind::None)
        throw Failure{E_FAIL,L"倒计时Esc未排空选区并取消，或意外创建媒体任务"};
    state.smokeNow=5000;
    if(!mc_recording_start(instance,nullptr))throw Failure{E_FAIL,L"取消后无法重新框选"};
    selection=state.selection;
    SendMessageW(selection,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(10,10));
    SendMessageW(selection,WM_LBUTTONUP,0,MAKELPARAM(11,11));
    if(!state.selection||recording_flow_value(state.flow,MC_RECORDING_PHASE)!=MC_RECORDING_SELECTING)
        throw Failure{E_FAIL,L"过小选区错误启动倒计时"};
    SendMessageW(selection,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(10,10));
    // Change the actual Win32 owner; merely sending WM_CAPTURECHANGED leaves
    // GetCapture() pointing at selection and creates an impossible loss state.
    // The OS sends the notification synchronously to the previous owner.
    if(SetCapture(state.host)!=selection||GetCapture()!=state.host)
        throw Failure{E_FAIL,L"鼠标捕获未真正从选区转交到另一个窗口"};
    SendMessageW(selection,WM_LBUTTONUP,0,MAKELPARAM(300,200));
    if(!state.selection||state.panel||GetCapture()!=state.host||
        recording_flow_value(state.flow,MC_RECORDING_PHASE)!=MC_RECORDING_SELECTING)
        throw Failure{E_FAIL,L"失去鼠标捕获后仍提交了选区或干扰新窗口的捕获"};
    SendMessageW(selection,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(20,30));
    if(GetCapture()!=selection)throw Failure{E_FAIL,L"新拖拽没有重新取得鼠标捕获"};
    SendMessageW(selection,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(340,270));
    SendMessageW(selection,WM_LBUTTONUP,0,MAKELPARAM(340,270));
    if(!state.panel||GetCapture()!=nullptr||recording_flow_value(state.flow,MC_RECORDING_PHASE)!=MC_RECORDING_COUNTDOWN)
        throw Failure{E_FAIL,L"第二次选区没有倒计时或未释放鼠标捕获"};
    SendMessageW(state.host,startedMessage,static_cast<WPARAM>(first),0);
    if(recording_flow_value(state.flow,MC_RECORDING_PHASE)!=MC_RECORDING_COUNTDOWN)
        throw Failure{E_FAIL,L"旧会话回调污染了当前选区"};
    SendMessageW(state.panel,WM_COMMAND,MAKEWPARAM(9300,BN_CLICKED),reinterpret_cast<LPARAM>(state.action));
    if(mc_recording_busy())throw Failure{E_FAIL,L"倒计时取消按钮未走共享命令"};
    if(!mc_recording_start(instance,nullptr))throw Failure{E_FAIL,L"取消按钮后无法重新框选"};
    SendMessageW(state.selection,WM_KEYDOWN,VK_ESCAPE,0);
    if(mc_recording_busy())throw Failure{E_FAIL,L"选区Esc未取消会话"};
    if(!mc_recording_start(instance,nullptr))throw Failure{E_FAIL,L"显示器变化测试无法开始"};
    selection=state.selection;
    SendMessageW(selection,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(20,30));
    SendMessageW(selection,WM_LBUTTONUP,0,MAKELPARAM(340,270));
    SendMessageW(state.panel,WM_DISPLAYCHANGE,0,0);
    if(mc_recording_busy())throw Failure{E_FAIL,L"显示器变化后仍保留过期录屏来源"};
    std::printf("Windows shared recording surface: passed (reverse drag, negative origin, tiny selection, lost capture, countdown, Esc/button cancel, stale callback).\n");
}
template<typename Ready> void pumpRecordingSmoke(Ready ready,DWORD timeout,const wchar_t *failure) {
    ULONGLONG started=GetTickCount64();double clock=state.smokeNow;
    while(!ready()) {
        MSG message;
        while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) {
            if(message.message==WM_QUIT)throw Failure{E_ABORT,L"录屏测试消息循环提前退出"};
            if(!mc_recording_handle_message(&message)){TranslateMessage(&message);DispatchMessageW(&message);}
        }
        ULONGLONG elapsed=GetTickCount64()-started;state.smokeNow=clock+static_cast<double>(elapsed);
        if(elapsed>=timeout)throw Failure{HRESULT_FROM_WIN32(WAIT_TIMEOUT),failure};
        Sleep(5);
    }
}
struct SmokeDelivery { fs::path source; unsigned count=0; };
bool receiveSmokeRecording(void *context,const wchar_t *source) {
    auto *delivery=static_cast<SmokeDelivery *>(context);delivery->source=source;delivery->count++;return true;
}
struct ScopedSmokeDelivery {
    MCRecordingCompleted previous=state.completed; void *context=state.completedContext;
    explicit ScopedSmokeDelivery(SmokeDelivery *delivery) { mc_recording_set_completed_callback(receiveSmokeRecording,delivery); }
    ~ScopedSmokeDelivery() { mc_recording_set_completed_callback(previous,context); }
};
void recordingLifecycleSmoke(HINSTANCE instance,const fs::path &directory) {
    SmokeDelivery delivered;ScopedSmokeDelivery callback(&delivered);
    // Exercise the actual deadline -> worker -> finalized original -> editor
    // path against the CI desktop, with every output confined to temp storage.
    // Pixel correctness is checked separately using a deterministic GDI source.
    state.smokeRealDesktop=true;state.smokeDirectory=directory/L"live-lifecycle";state.smokeNow=10000;
    if(!mc_recording_start(instance,nullptr)||!state.selection)throw Failure{E_FAIL,L"录制闭环没有进入真实选区窗口"};
    int32_t flow=state.flow;HWND selection=state.selection;
    MONITORINFO monitor={};monitor.cbSize=sizeof(monitor);
    if(!GetMonitorInfoW(MonitorFromPoint(POINT{0,0},MONITOR_DEFAULTTOPRIMARY),&monitor))
        throw Failure{E_FAIL,L"录制测试无法定位显示器"};
    int x=monitor.rcMonitor.left+16-state.desktopBounds.left,y=monitor.rcMonitor.top+16-state.desktopBounds.top;
    if(monitor.rcMonitor.right-monitor.rcMonitor.left<352||monitor.rcMonitor.bottom-monitor.rcMonitor.top<272||x+320>32767||y+240>32767)
        throw Failure{E_FAIL,L"录制测试需要至少 352 × 272 的显示器"};
    SendMessageW(selection,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(x,y));
    SendMessageW(selection,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(x+320,y+240));
    SendMessageW(selection,WM_LBUTTONUP,0,MAKELPARAM(x+320,y+240));
    if(recording_flow_value(flow,MC_RECORDING_PHASE)!=MC_RECORDING_COUNTDOWN||state.kind!=JobKind::None)
        throw Failure{E_FAIL,L"录制闭环选区未进入倒计时"};
    state.smokeNow=13000;SendMessageW(state.host,WM_TIMER,flowTimer,0);
    if(recording_flow_value(flow,MC_RECORDING_PHASE)!=MC_RECORDING_STARTING||state.kind!=JobKind::Recording||!state.worker.joinable())
        throw Failure{E_FAIL,L"倒计时截止没有创建真实采集任务"};
    fs::path original=state.source;
    if(state.directory.parent_path()!=state.smokeDirectory||IsWindowVisible(state.panel)||IsWindowVisible(state.tooltip))
        throw Failure{E_FAIL,L"录制测试输出未隔离，或倒计时仍显示在首帧中"};
    pumpRecordingSmoke([]{return mc_recording_recording()||state.kind==JobKind::None;},15000,L"真实采集没有回报开始");
    if(!mc_recording_recording())throw Failure{E_FAIL,L"真实采集失败，未进入共享录制状态"};
    ULONGLONG began=GetTickCount64();
    pumpRecordingSmoke([began]{return GetTickCount64()-began>=600||state.kind==JobKind::None;},5000,L"真实采集计时未推进");
    if(state.kind!=JobKind::Recording)throw Failure{E_FAIL,L"未停止时采集意外退出"};
    mc_recording_stop();
    if(recording_flow_value(flow,MC_RECORDING_PHASE)!=MC_RECORDING_STOPPING||!state.worker.joinable())
        throw Failure{E_FAIL,L"停止录制未等待媒体收尾"};
    pumpRecordingSmoke([]{return state.kind==JobKind::None;},15000,L"媒体没有完成封装并回报完成");
    if(state.flow||recording_flow_value(flow,MC_RECORDING_PHASE)!=-1||state.worker.joinable()||state.selection||state.panel||
        state.frozen||state.dimmed||delivered.count!=1||delivered.source!=original||!fs::is_regular_file(original))
        throw Failure{E_FAIL,L"完成后未释放录屏资源或没有交付原片到编辑器"};
    {MediaRuntime runtime;Decoder decoder(original,15);std::vector<BYTE> pixels;LONGLONG time=0,length=0;
        if(decoder.width!=320||decoder.height!=240||decoder.duration<second/4||!decoder.next(pixels,time,length))
            throw Failure{E_FAIL,L"闭环原片尺寸、时长或可播放性不正确"};}
    auto size=fs::file_size(original);mc_recording_close();
    if(mc_recording_busy()||fs::file_size(original)!=size||delivered.count!=1)
        throw Failure{E_FAIL,L"录屏关闭没有保留原片，或重复交付给应用"};
    state.smokeRealDesktop=false;state.smokeDirectory.clear();
    std::printf("Windows region recording lifecycle: passed (entry, surface, countdown deadline, capture worker, stop/finalize, playable original, app delivery, cleanup).\n");
}
extern "C" int mc_recording_smoke(HINSTANCE instance) {
    try {
        // The App must register delivery in its common startup path. The
        // isolated capture fixture below replaces it temporarily, never
        // compensates for a missing production registration.
        if(!state.completed)throw Failure{E_FAIL,L"应用启动未注册录屏完成交付入口"};
        selectionFlowSmoke(instance);
        MCCoreRecordingPlan recording=recordingPlan(320,240),large=recordingPlan(5120,2880),portrait=recordingPlan(1080,1920);
        if(recording.width!=320 || recording.height!=240 || recording.frames_per_second!=15 ||
            large.width!=1920 || large.height!=1080 || portrait.width!=606 || portrait.height!=1080)
            throw Failure{E_FAIL,L"共享录屏参数未保持 Windows 尺寸和帧率"};
        UINT32 frameRate=static_cast<UINT32>(recording.frames_per_second);
        MediaRuntime runtime;fs::path directory=fs::temp_directory_path()/L"moojicut-recording-smoke"/identifier();fs::create_directories(directory);
        recordingLifecycleSmoke(instance,directory);
        fs::path source=directory/L"source.mp4";
        {Encoder encoder(source,320,240,frameRate);std::vector<BYTE> pixels(320*240*4);
            for(UINT32 frame=0;frame<60;frame++){
                for(UINT32 y=0;y<240;y++)for(UINT32 x=0;x<320;x++){size_t offset=(static_cast<size_t>(y)*320+x)*4;pixels[offset]=static_cast<BYTE>(y);pixels[offset+1]=static_cast<BYTE>(x);pixels[offset+2]=static_cast<BYTE>(frame*4);pixels[offset+3]=255;}
                LONGLONG now=static_cast<LONGLONG>(frame)*second/frameRate,next=static_cast<LONGLONG>(frame+1)*second/frameRate;encoder.frame(pixels.data(),now,next-now);
            }encoder.finish();}
        // The same GDI copy used by live recording must crop the chosen physical
        // region, including a desktop whose origin is on a left-hand monitor.
        fs::path regionFile=directory/L"selected-region.mp4";
        {DesktopSurface fixture(640,480),selected(320,240);
            for(UINT32 y=0;y<480;y++)for(UINT32 x=0;x<640;x++){
                size_t offset=(static_cast<size_t>(y)*640+x)*4;fixture.pixels[offset]=static_cast<BYTE>(y/2);
                fixture.pixels[offset+1]=static_cast<BYTE>(x/3);fixture.pixels[offset+2]=127;fixture.pixels[offset+3]=255;
            }
            SetWindowOrgEx(fixture.memory,-240,80,nullptr);
            captureDesktopFrame(selected,fixture.memory,RECT{-180,160,140,400},320,240);GdiFlush();
            Encoder encoder(regionFile,320,240,frameRate);
            for(UINT32 i=0;i<15;i++)encoder.frame(selected.pixels,static_cast<LONGLONG>(i)*second/frameRate,second/frameRate);
            encoder.finish();}
        {Decoder decoder(regionFile,frameRate);std::vector<BYTE> pixels;LONGLONG time=0,length=0;
            if(decoder.width!=320||decoder.height!=240||!decoder.next(pixels,time,length))
                throw Failure{E_FAIL,L"所选区域没有生成可播放且尺寸正确的原片"};
            const BYTE *center=pixels.data()+(120*320+160)*4;
            if(std::abs(static_cast<int>(center[0])-100)>20||std::abs(static_cast<int>(center[1])-73)>20)
                throw Failure{E_FAIL,L"采集偏移未使用选区的物理像素坐标"};}
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
        // Capture format remains independently checked. Editing/cropping,
        // exports and draft recovery now exercise the shared v2 host in the
        // gst-media/media-worker/windows-video-editor fixtures, not a retired
        // native form or another Media Foundation editing implementation.
        Decoder decoder(source,frameRate);
        if(decoder.width!=320||decoder.height!=240||std::llabs(decoder.duration-4*second)>second/6||decoder.hasAudio())
            throw Failure{E_FAIL,L"录制原片尺寸、时长或无音轨检查失败"};
        ComPtr<IMFMediaType> actual;UINT32 rateNumerator=0,rateDenominator=0;
        check(decoder.reader->GetCurrentMediaType(videoStream,&actual),L"无法读取原片帧率");
        check(MFGetAttributeRatio(actual.Get(),MF_MT_FRAME_RATE,&rateNumerator,&rateDenominator),L"原片没有帧率信息");
        if(!rateDenominator||rateNumerator!=frameRate*rateDenominator)throw Failure{E_FAIL,L"原片帧率与共享录制策略不一致"};
        std::vector<BYTE> pixels;LONGLONG time=0,length=0;
        if(!decoder.next(pixels,time,length))throw Failure{E_FAIL,L"原片没有画面"};
        const BYTE *center=pixels.data()+(120*320+160)*4;
        if(std::abs(static_cast<int>(center[0])-120)>20||std::abs(static_cast<int>(center[1])-160)>20)
            throw Failure{E_FAIL,L"原片RGB方向或像素位置不正确"};
        std::printf("Windows Media Foundation recording/source-preservation smoke passed.\n");return 0;
    }catch(const Failure &error){std::fprintf(stderr,"Recording smoke failed: %s\n",utf8(description(error)).c_str());}
    catch(const std::exception &){std::fprintf(stderr,"Recording smoke failed: native exception.\n");}
    if(GetCapture()==state.host)ReleaseCapture();
    // Even failed assertions must stop/finalize the real worker before a core
    // failure acknowledgement or teardown releases its session resources.
    if(state.kind==JobKind::Recording){
        mc_recording_stop();if(state.worker.joinable())state.worker.join();
        MSG message;while(PeekMessageW(&message,state.host,doneMessage,doneMessage,PM_REMOVE))DispatchMessageW(&message);
    }
    if(state.flow){clearSelection();closeFlowPanel();recording_flow_event(state.flow,MC_RECORDING_FAIL,flowNow());releaseFlow();}
    state.kind=JobKind::None;
    return 1;
}

#include "CDesktopUI.h"
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <UIAutomation.h>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

/* Geometry and control kind only: no names, values, text, screenshots or Invoke. */
static int inspect(IUIAutomation *automation, uint32_t window, int x, int y) {
    HWND hwnd=(HWND)(uintptr_t)window;
    DWORD pid=0;GetWindowThreadProcessId(hwnd,&pid);
    if (!IsWindow(hwnd) || pid==GetCurrentProcessId()) return -1;
    IUIAutomationElement *root=nullptr;IUIAutomationTreeWalker *walker=nullptr;
    if (FAILED(automation->ElementFromHandle((UIA_HWND)hwnd,&root)) || !root) return -1;
    if (FAILED(automation->get_ControlViewWalker(&walker)) || !walker) {root->Release();return -1;}
    struct Node {IUIAutomationElement *element;int depth;};
    std::vector<Node> pending;pending.push_back({root,0});
    int answer=0,visited=0;ULONGLONG deadline=GetTickCount64()+200;
    while (!pending.empty() && visited<256 && GetTickCount64()<deadline) {
        Node node=pending.back();pending.pop_back();++visited;
        RECT rect={};BOOL enabled=FALSE;CONTROLTYPEID type=0;
        bool bounded=SUCCEEDED(node.element->get_CurrentBoundingRectangle(&rect));
        bool contains=bounded && x>=rect.left && x<rect.right && y>=rect.top && y<rect.bottom;
        bool empty=bounded && rect.left==rect.right && rect.top==rect.bottom;
        if (SUCCEEDED(node.element->get_CurrentIsEnabled(&enabled)) && enabled && (contains || empty)) {
            if (contains && SUCCEEDED(node.element->get_CurrentControlType(&type))) {
                switch (type) {
                case UIA_ButtonControlTypeId:case UIA_CheckBoxControlTypeId:case UIA_RadioButtonControlTypeId:
                case UIA_ComboBoxControlTypeId:case UIA_EditControlTypeId:case UIA_HyperlinkControlTypeId:
                case UIA_MenuItemControlTypeId:case UIA_TabItemControlTypeId:case UIA_SliderControlTypeId:
                case UIA_SpinnerControlTypeId:case UIA_SplitButtonControlTypeId:case UIA_TreeItemControlTypeId:
                    answer=1;break;
                default:break;
                }
            }
            if (node.depth<24) {
                IUIAutomationElement *child=nullptr;
                if (SUCCEEDED(walker->GetFirstChildElement(node.element,&child))) {
                    int siblings=0;
                    while (child && siblings++<128 && pending.size()<256) {
                        IUIAutomationElement *next=nullptr;
                        walker->GetNextSiblingElement(child,&next);
                        pending.push_back({child,node.depth+1});child=next;
                    }
                    if (child) child->Release();
                }
            }
        }
        node.element->Release();
    }
    for (const Node& node:pending) node.element->Release();
    walker->Release();return answer;
}
struct PointerWorker {
    std::mutex mutex;std::condition_variable wake;
    uint32_t window=0;int x=0,y=0,result=-1;uint64_t generation=0,completed=0;
    ULONGLONG completedAt=0;bool requested=false;
    PointerWorker() {
        // The OS reclaims this worker with Castor; no external helper/service is started.
        std::thread([this] {
            HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
            IUIAutomation *automation=nullptr;
            if (SUCCEEDED(com)) CoCreateInstance(__uuidof(CUIAutomation),nullptr,CLSCTX_INPROC_SERVER,__uuidof(IUIAutomation),(void**)&automation);
            for (;;) {
                std::unique_lock<std::mutex> lock(mutex);wake.wait(lock,[this]{return requested;});
                uint32_t target=window;int px=x,py=y;uint64_t ticket=generation;requested=false;lock.unlock();
                int value=automation ? inspect(automation,target,px,py):-1;
                lock.lock();if (ticket==generation) {result=value;completed=ticket;completedAt=GetTickCount64();}
            }
        }).detach();
    }
};
int castor_pointer_actionable(uint32_t window,int x,int y) {
    static PointerWorker *worker=new PointerWorker();
    std::lock_guard<std::mutex> lock(worker->mutex);
    ULONGLONG now=GetTickCount64();
    if (worker->window!=window || worker->x!=x || worker->y!=y || (worker->completed==worker->generation && now-worker->completedAt>200)) {
        worker->window=window;worker->x=x;worker->y=y;++worker->generation;worker->requested=true;worker->wake.notify_one();
    }
    return worker->completed==worker->generation && now-worker->completedAt<=250 ? worker->result:-1;
}
#else
int castor_pointer_actionable(uint32_t window,int x,int y) {(void)window;(void)x;(void)y;return -1;}
#endif

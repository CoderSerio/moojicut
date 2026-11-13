///|
using @rabbita {type Val}
///|
using @html {type Html}
///|
using @cmd {trait Scheduler}
///|
enum Msg { State(String); Action(String, String) }
///|
priv suberror UiSubscription { UiSubscription(@cmd.Emit[String]) }
///|
extern "js" fn listen(callback : (String) -> Unit) -> (() -> Unit) =
  #|(callback) => { const fn = event => callback(event.detail); window.addEventListener('mooncap:image-ui', fn); queueMicrotask(() => callback(JSON.stringify(window.mooncapImageUiState || {}))); return () => window.removeEventListener('mooncap:image-ui', fn); }
///|
extern "js" fn dispatch(action : String, value : String) -> Unit =
  #|(action, value) => { window.mooncapImageAction?.(action, value); }
///|
fn subscription(payload : Error, scheduler : &Scheduler) -> @sub.RunningSub? {
  match payload {
    UiSubscription(emit) => {
      let mut current = emit
      let dispose = listen(value => scheduler.add(current(value)))
      Some({ unload: _ => dispose(), update_tagger: value => { match value { UiSubscription(next) => current = next; _ => () } } })
    }
    _ => None
  }
}
///|
fn string(m : Map[String, @json.Json], key : String, fallback : String) -> String {
  match m.get(key) { Some(String(s)) => s; Some(Number(n, ..)) => n.to_string(); Some(True) => "true"; Some(False) => "false"; _ => fallback }
}
///|
fn yes(m : Map[String, @json.Json], key : String) -> Bool { string(m,key,"false") == "true" }
///|
fn choice(label : String, key : String, options : Array[(String, String)], style : Map[String, @json.Json], emit : @cmd.Emit[Msg]) -> Html {
  @html.label(class="field", [@html.span(label), @html.select(title=label, attrs=@html.Attrs::build().aria_label(label), on_change=@cmd.Emit(v => emit(Action("style:" + key, v))), options.map(option => @html.option(value=option.0, selected=string(style,key,options[0].0)==option.0,option.1)))])
}
///|
fn number_field(label : String, key : String, minimum : Int, maximum : Int, style : Map[String, @json.Json], emit : @cmd.Emit[Msg]) -> Html {
  @html.label(class="field", [@html.span(label), @html.input(input_type=@html.Number, min=minimum, max=maximum, value=string(style,key,minimum.to_string()), attrs=@html.Attrs::build().aria_label(label).disabled(key=="stroke"&&yes(style,"fill")), on_change=@cmd.Emit(v => emit(Action("style:" + key,v))))])
}
///|
fn view(text : String, emit : @cmd.Emit[Msg]) -> Html {
  let state = match (@json.parse(text) catch { _ => @json.Json::null() }) { Object(m) => m; _ => Map([]) }
  let style = match state.get("style") { Some(Object(m)) => m; _ => Map([]) }
  let tool = string(state,"tool","select")
  let kind = string(state,"kind",tool)
  let selected = yes(state,"selected")
  let busy = yes(state,"busy")
  let buttons : Array[Html] = []
  for item in [("shape","□","形状 R"),("arrow","↗","线条 A"),("pencil","✎","画笔 P"),("marker","▰","荧光笔 H"),("redaction","▦","遮挡 B"),("text","T","文字 T"),("eraser","⌫","擦除整条标注 E")] {
    buttons.push(@html.button(class=if tool==item.0 {"tool active"} else {"tool"}, title=item.2, attrs=@html.Attrs::build().aria_label(item.2).aria_pressed((tool==item.0).to_string()), disabled=busy, on_click=emit(Action("tool",item.0)),item.1))
  }
  buttons.push(@html.span(class="divider",""))
  buttons.push(@html.button(title="撤销 Mod+Z",attrs=@html.Attrs::build().aria_label("撤销"),disabled=busy||!yes(state,"canUndo"),on_click=emit(Action("undo","")),"↶"))
  buttons.push(@html.button(title="重做 Mod+Shift+Z",attrs=@html.Attrs::build().aria_label("重做"),disabled=busy||!yes(state,"canRedo"),on_click=emit(Action("redo","")),"↷"))
  buttons.push(@html.span(class="divider",""))
  for item in [("cancel","×","取消 Esc"),("pin","◇","贴图"),("save","↓","保存 PNG"),("copy","✓","确认并复制图片 Enter")] {
    buttons.push(@html.button(class=if item.0=="copy" {"confirm"} else {""}, title=item.2,attrs=@html.Attrs::build().aria_label(item.2),disabled=busy,on_click=emit(Action(item.0,"")),item.1))
  }
  let fields : Array[Html] = []
  if kind=="shape"||kind=="rect"||kind=="ellipse" {
    fields.push(number_field("粗细","stroke",1,32,style,emit))
    fields.push(choice("填充","fill",[("false","空心"),("true","实心")],style,emit))
    if !selected { fields.push(choice("形状","shape",[("rect","矩形"),("ellipse","椭圆")],style,emit)) }
  } else if kind=="arrow" {
    fields.push(number_field("粗细","stroke",1,32,style,emit))
    fields.push(choice("线型","dash",[("false","实线"),("true","虚线")],style,emit))
    fields.push(choice("箭头","arrowHead",[("none","无线头"),("end","单向"),("both","双向")],style,emit))
  } else if kind=="pencil"||kind=="marker" {
    fields.push(number_field("粗细","stroke",1,96,style,emit))
  } else if kind=="redaction"||kind=="redact"||kind=="mosaic" {
    if !selected { fields.push(choice("方式","effect",[("redact","实色"),("mosaic","马赛克")],style,emit)) }
    if kind=="mosaic"||string(style,"effect","")=="mosaic" { fields.push(number_field("块大小","blockSize",4,48,style,emit)) }
  } else if kind=="text" {
    fields.push(number_field("字号","fontSize",8,128,style,emit))
    fields.push(choice("字重","bold",[("false","常规"),("true","粗体")],style,emit))
    fields.push(choice("对齐","align",[("left","左"),("center","中"),("right","右")],style,emit))
  }
  if kind!="select"&&kind!="crop"&&kind!="eraser"&&kind!="mosaic"&&!(kind=="redaction"&&string(style,"effect","")=="mosaic") {
    fields.push(@html.input(input_type=@html.Color,title="颜色",attrs=@html.Attrs::build().aria_label("颜色"),value=string(style,"color","#ef4444"),on_input=@cmd.Emit(v=>emit(Action("preview:color",v))),on_change=@cmd.Emit(v=>emit(Action("style:color",v)))))
    fields.push(@html.input(input_type=@html.Text,class="hex",title="十六进制颜色",attrs=@html.Attrs::build().aria_label("十六进制颜色"),value=string(style,"color","#ef4444"),on_change=@cmd.Emit(v=>emit(Action("style:color",v)))))
    if kind!="redact"&&kind!="redaction" { fields.push(number_field("透明 %","opacityPercent",1,100,style,emit)) }
  }
  if kind=="eraser" { fields.push(@html.span("拖过标注，擦除整个对象")) }
  if selected {
    fields.push(@html.button(on_click=emit(Action("delete","")),"删除"))
    if kind!="redact"&&kind!="mosaic" { for item in [("front","置顶"),("back","置底")] { fields.push(@html.button(on_click=emit(Action(item.0,"")),item.1)) } }
  }
  @html.div([
    @html.div(class="toolbar",buttons),
    @html.div(class="properties",fields),
    @html.div(class="status-row",[
      @html.button(class="quiet",on_click=emit(Action("tool","select")),"选择 V"),
      @html.button(class="quiet",on_click=emit(Action("tool","crop")),"调整选区 C"),
      @html.span(string(state,"status","选择与移动")),
    ]),
  ])
}
///|
fn app() -> Val[Html] {
  let (model, emit) = @rabbita.create_state("{}", update=(model,msg,_emit)=>match msg {
    State(value) => (value,@cmd.none)
    Action(action,value) => (model,@cmd.effect(fn() noraise { dispatch(action,value) }))
  }, subscriptions=(_model,emit)=>@sub.custom_sub("image-ui",@sub.Local,UiSubscription(@cmd.Emit(v=>emit(State(v)))),@sub.SubLoader(subscription)))
  model.view(text=>view(text,emit))
}
///|
fn main { @rabbita.new(app).mount("image-tools") }

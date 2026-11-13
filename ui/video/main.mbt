///|
extern "js" fn dispatch(action : String) -> Unit =
  #|action => window.mooncapVideo.dispatch(action)

///|
fn action(id : String, label : String, class_name? : String = "") -> @html.Html {
  @html.button(id~, class=class_name, type_="button", on_click=@cmd.custom_cmd(_ => dispatch(id)), label)
}

///|
fn numeric(id : String, label : String, initial? : String = "0") -> @html.Html {
  @html.label(for_=id, class="field", [
    @html.span(label),
    @html.input(id~, input_type=@html.Number, value=initial, min=0, step=1),
  ])
}

///|
fn panel(title : String, body : Array[@html.Html]) -> @html.Html {
  @html.section(class="edit-section", [@html.h2(title), @html.div(class="section-body", body)])
}

///|
fn main {
  @rabbita.new(() => @rabbita.Val::constant(@html.div(class="video-controls", [
    @html.div(class="edit-history", [action("undo", "↶ 撤销"), action("redo", "↷ 重做"), action("reset", "恢复原始剪辑")]),
    @html.div(class="edit-options", [
    panel("保留范围", [
      @html.p(class="help", "拖动首尾手柄或输入原片时间（秒）。"),
      @html.div(class="fields two", [numeric("trim-start", "起点"), numeric("trim-end", "终点")]),
      @html.div(class="button-row", [action("set-start", "当前帧设为起点"), action("set-end", "当前帧设为终点")]),
    ]),
    panel("删除片段", [
      @html.div(class="fields two", [numeric("cut-start", "从"), numeric("cut-end", "至")]),
      @html.div(class="button-row", [action("delete-cut", "删除所选片段"), action("clear-cuts", "恢复所有片段")]),
      @html.p(id="cut-summary", class="help", "尚未删除片段"),
    ]),
    panel("画面裁切", [
      @html.p(class="help", "开启后在画面上拖出裁切框。可拖动内部与角点调整。"),
      @html.div(class="button-row", [action("crop-toggle", "调整裁切框"), action("crop-original", "原始比例")]),
      @html.div(class="fields four", [numeric("crop-x", "X"), numeric("crop-y", "Y"), numeric("crop-width", "宽"), numeric("crop-height", "高")]),
      @html.div(class="button-row", [action("apply-crop", "应用裁切"), action("clear-crop", "恢复全画面")]),
    ]),
    panel("声音与输出", [
      @html.label(class="checkbox", [@html.input(id="mute", input_type=@html.Checkbox), @html.span("整段静音")]),
      @html.label(class="field", [@html.span("输出预设"), @html.select(id="preset", [@html.option(value="share", "适合分享 · 1280 px"), @html.option(value="quality", "更清晰 · 1920 px")])]),
      @html.p(id="estimate", class="help", "正在读取视频…"),
    ]),
    ]),
    @html.div(class="confirm-area", [
      action("confirm", "确认并复制", class_name="primary"), action("save-as", "另存为…"),
      @html.div(id="export-actions", hidden=true, [action("retry-copy", "复制已生成视频"), action("reveal-export", "显示文件位置"), action("copy-path", "复制路径")]),
      @html.div(id="export-status", hidden=true, [@html.progress(id="export-progress", max=100, value=0, ""), @html.p(id="export-message", "正在准备…"), action("cancel-export", "取消导出")]),
    ]),
  ]))).mount("video-controls")
}

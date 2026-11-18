///|
pub struct CapturePluginCall {
  priv lease : @runtime.Invocation
  priv wire : @contract.PluginInvocation
  priv capture : Int32
  priv revision : Double
}

///|
pub(all) enum CapturePluginResult {
  ShowText(String, String)
  DocumentChanged
  Discarded
}

///|
pub fn InstalledPlugin::begin_capture_call(
  self : InstalledPlugin,
  owner : @runtime.OwnerSnapshot,
  tool_id : String,
  request_id : String,
  selection : @contract.PluginSelection?,
) -> CapturePluginCall raise @protocol.InputError {
  let code = "stale_invocation"
  let capture = owner.owner
  if @capture.image_session_revision(capture) != owner.revision {
    raise @protocol.InputError(
      code, "The screenshot changed before the call could start",
    )
  }
  let installed = match self.runtime.package_snapshot(self.manifest.plugin_id) {
    Some(installed) if installed.install_generation ==
      self.installed.install_generation &&
      installed.content == self.installed.content => installed
    _ =>
      raise @protocol.InputError(
        code, "The package version changed before the call could start",
      )
  }
  let wire = self.manifest.prepare_invocation(tool_id, request_id, {
    width: @capture.image_session_viewport_value(capture, 2).to_int(),
    height: @capture.image_session_viewport_value(capture, 3).to_int(),
    revision: owner.revision,
    selection,
  })
  let lease = match
    self.runtime.begin_invocation(
      self.manifest.plugin_id,
      installed.generation,
      tool_id,
      owner,
      request_id,
    ) {
    Some(lease) => lease
    None =>
      raise @protocol.InputError(
        code, "The contribution is disabled or the call is no longer current",
      )
  }
  { lease, wire, capture, revision: owner.revision, }
}

///|
pub fn CapturePluginCall::request(self : CapturePluginCall) -> String {
  self.wire.request()
}

///|
pub fn CapturePluginCall::needs_cancel(self : CapturePluginCall) -> Bool {
  self.lease.needs_cancel()
}

///|
// A failed or cancelled worker must still acknowledge resource cleanup.
pub fn CapturePluginCall::worker_failed(self : CapturePluginCall) -> Unit {
  ignore(self.lease.reject())
  ignore(self.lease.worker_drained())
}

///|
pub fn CapturePluginCall::complete(
  self : CapturePluginCall,
  output : String,
) -> CapturePluginResult raise @protocol.InputError {
  if !self.lease.worker_drained() || !(self.lease.phase() is Running) {
    return Discarded
  }
  if @capture.image_session_revision(self.capture) != self.revision {
    ignore(self.lease.reject())
    return Discarded
  }
  errdefer ignore(self.lease.reject())
  let result = self.wire.validate_output(output)
  let permit = match self.lease.prepare_result(self.wire.effect_key()) {
    Some(permit) => permit
    None => return Discarded
  }
  match result {
    Text(title, text) =>
      if permit.commit() {
        ShowText(title, text)
      } else {
        Discarded
      }
    Annotations(annotations) => {
      let candidate = @capture.image_session_prepare_plugin_annotations(
        self.capture,
        self.revision,
        Json::array(annotations).stringify(),
      )
      if candidate == 0 {
        ignore(permit.abort())
        return Discarded
      }
      // Both commits run on the same application thread without effects/callbacks
      // between them. A failed candidate cannot consume or mutate the document.
      if !permit.ready() ||
        @capture.candidate_commit(self.capture, candidate) == 0 {
        ignore(@capture.candidate_close(candidate))
        ignore(permit.abort())
        return Discarded
      }
      ignore(permit.commit())
      DocumentChanged
    }
  }
}

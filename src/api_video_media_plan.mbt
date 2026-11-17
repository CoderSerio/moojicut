///|
#export_name("video_media_plan_open")
pub fn video_media_plan_open(session : Int) -> Int {
  @video_project.media_plan_open(session)
}

///|
#export_name("video_media_plan_close")
pub fn video_media_plan_close(handle : Int) -> Unit {
  @video_project.media_plan_close(handle)
}

///|
#export_name("video_media_plan_value")
pub fn video_media_plan_value(handle : Int, key : Int) -> Int {
  @video_project.media_plan_value(handle, key)
}

///|
#export_name("video_media_plan_number")
pub fn video_media_plan_number(handle : Int, key : Int) -> Double {
  @video_project.media_plan_number(handle, key)
}

///|
#export_name("video_media_plan_clip_number")
pub fn video_media_plan_clip_number(
  handle : Int, kind : Int, index : Int, key : Int,
) -> Double {
  @video_project.media_plan_clip_number(handle, kind, index, key)
}

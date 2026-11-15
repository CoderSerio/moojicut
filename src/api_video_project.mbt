///|
#export_name("video_project_open")
pub fn video_project_open(source : String, draft : String) -> String {
  @video_project.open(source, draft)
}

///|
#export_name("video_project_command")
pub fn video_project_command(session : Int, command : String) -> String {
  @video_project.command(session, command)
}

///|
#export_name("video_project_snapshot")
pub fn video_project_snapshot(session : Int) -> String {
  @video_project.snapshot(session)
}

///|
#export_name("video_project_close")
pub fn video_project_close(session : Int) -> Unit {
  @video_project.close(session)
}

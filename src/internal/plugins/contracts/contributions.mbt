///|
// Declarative contribution data. Concrete commands/titles/defaults belong to
// feature extensions; the runtime only validates, orders and snapshots them.
pub(all) struct ToolContribution {
  id : String
  plugin_id : String
  target : String
  title : String
  icon : String
  slot : String
  behavior : String
  command : String
  interaction : String
  annotation_kind : Int32
  default_enabled : Bool
  capability : Int32
  requires : String
  payload : @json.Json
}

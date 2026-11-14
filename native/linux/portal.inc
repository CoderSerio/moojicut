static void portal_response(GDBusConnection *bus, const char *sender, const char *path, const char *interface,
                            const char *signal, GVariant *parameters, gpointer data) {
  (void)bus;
  (void)sender;
  (void)interface;
  (void)signal;
  if (GPOINTER_TO_UINT(data) != generation || !capture.pending || g_strcmp0(path, capture.request_path))
    return;
  guint result;
  GVariant *values;
  g_variant_get(parameters, "(u@a{sv})", &result, &values);
  char *uri = NULL;
  g_variant_lookup(values, "uri", "s", &uri);
  g_variant_unref(values);
  release_portal(FALSE);
  if (result != 0 || !uri) {
    report(result == 1 ? "截图已取消，剪贴板未更改。"
                       : "系统未允许截图，剪贴板未更改。请检查截图门户和权限。");
    g_free(uri);
    mc_linux_capture_close();
    return;
  }
  GFile *file = g_file_new_for_uri(uri);
  char *filename = g_file_get_path(file);
  GError *error = NULL;
  GdkPixbuf *image = filename ? gdk_pixbuf_new_from_file(filename, &error) : NULL;
  gboolean ok = image && open_editor(image);
  g_clear_object(&image);
  g_object_unref(file);
  g_free(filename);
  g_free(uri);
  g_clear_error(&error);
  if (!ok) {
    report("无法读取系统提供的截图。剪贴板未更改。");
    mc_linux_capture_close();
  }
}
static void portal_started(GObject *object, GAsyncResult *result, gpointer data) {
  GError *error = NULL;
  GVariant *response = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error);
  if (GPOINTER_TO_UINT(data) != generation || !capture.pending) {
    /* A cancellation can race the method reply on older portal versions that
       return a different request path. Close that actual handle as well. */
    if (response && GPOINTER_TO_UINT(data) != generation) {
      const char *path;
      g_variant_get(response, "(&o)", &path);
      g_dbus_connection_call(G_DBUS_CONNECTION(object), "org.freedesktop.portal.Desktop", path,
                             "org.freedesktop.portal.Request", "Close", NULL, NULL, G_DBUS_CALL_FLAGS_NONE,
                             3000, NULL, NULL, NULL);
    }
    g_clear_pointer(&response, g_variant_unref);
    g_clear_error(&error);
    return;
  }
  if (!response) {
    report("当前桌面未提供可用的截图门户，请安装并启用对应的 xdg-desktop-portal 后端。");
    g_clear_error(&error);
    mc_linux_capture_close();
    return;
  }
  const char *path;
  g_variant_get(response, "(&o)", &path);
  if (g_strcmp0(path, capture.request_path)) {
    g_dbus_connection_signal_unsubscribe(capture.bus, capture.subscription);
    g_free(capture.request_path);
    capture.request_path = g_strdup(path);
    capture.subscription = g_dbus_connection_signal_subscribe(
        capture.bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response", path,
        NULL, G_DBUS_SIGNAL_FLAGS_NONE, portal_response, data, NULL);
  }
  g_variant_unref(response);
}
static void start_portal(void) {
  GError *error = NULL;
  capture.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
  if (!capture.bus) {
    report("无法连接系统截图服务。请确认桌面会话的 D-Bus 正常运行。");
    g_clear_error(&error);
    mc_linux_capture_close();
    return;
  }
  char *sender = g_strdup(g_dbus_connection_get_unique_name(capture.bus) + 1);
  for (char *p = sender; *p; p++)
    if (*p == '.')
      *p = '_';
  char *token = g_strdup_printf("moojicut_%u_%u", generation, g_random_int());
  capture.request_path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
  capture.pending = TRUE;
  capture.subscription = g_dbus_connection_signal_subscribe(
      capture.bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
      capture.request_path, NULL, G_DBUS_SIGNAL_FLAGS_NONE, portal_response, GUINT_TO_POINTER(generation),
      NULL);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
  g_variant_builder_add(&options, "{sv}", "interactive", g_variant_new_boolean(TRUE));
  g_dbus_connection_call(capture.bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                         "org.freedesktop.portal.Screenshot", "Screenshot",
                         g_variant_new("(s@a{sv})", "", g_variant_builder_end(&options)),
                         G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 10000, NULL, portal_started,
                         GUINT_TO_POINTER(generation));
  g_free(sender);
  g_free(token);
}

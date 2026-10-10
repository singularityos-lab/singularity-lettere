project('singularity-lettere', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-lettere"', language: 'c')
subdir('po')

gtk_dep = dependency('gtk4', version: '>= 4.16')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
soup_dep = dependency('libsoup-3.0')
secret_dep = dependency('libsecret-1')
sqlite_dep = dependency('sqlite3')
webkit_dep = dependency('webkitgtk-6.0')
poppler_dep = dependency('poppler-glib')
unix_print_dep = dependency('gtk4-unix-print')
gst_dep = dependency('gstreamer-1.0')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

core_sources = files(
  'src/mime.vala',
  'src/html.vala',
  'src/imap.vala',
  'src/smtp.vala',
  'src/threading.vala',
  'src/autoconfig.vala',
  'src/account.vala',
  'src/store.vala',
  'src/search.vala',
  'src/contacts.vala',
  'src/sieve.vala',
  'src/rules.vala',
  'src/api.vala',
  'src/backend.vala',
  'src/pop.vala',
  'src/graph.vala',
  'src/gmail.vala',
  'src/jmap.vala',
  'src/ews.vala',
  'src/stores.vala',
  'src/merge.vala',
  'src/mbox.vala',
  'src/mapi.vala',
  'src/pst.vala',
  'src/msg.vala',
  'src/msg_writer.vala',
  'src/pst_writer.vala',
  'src/crypto.vala',
  'src/outgoing.vala',
  'src/sync.vala',
)

math_dep = meson.get_compiler('c').find_library('m', required: false)

core_deps = [dependency('gio-2.0'), gee_dep, json_dep, soup_dep, secret_dep, sqlite_dep, math_dep]

executable('singularity-lettere',
  core_sources + files(
    'src/rows.vala',
    'src/integration.vala',
    'src/invite.vala',
    'src/editor.vala',
    'src/reader.vala',
    'src/mail_print.vala',
    'src/composer.vala',
    'src/account_dialog.vala',
    'src/dialogs.vala',
    'src/importer.vala',
    'src/online.vala',
    'src/window.vala',
    'src/test_script.vala',
    'src/mail_service.vala',
    'src/notifications.vala',
    'src/summary.vala',
    'src/app.vala',
  ),
  dependencies: core_deps + [gtk_dep, webkit_dep, poppler_dep, unix_print_dep, gst_dep, libsingularity_dep],
  install: true
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.lettere.service.in',
  output: 'dev.sinty.lettere.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/dev.sinty.lettere.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.lettere.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.lettere.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/capabilities/dev.sinty.Lettere.Mail.ini',
  install_dir: get_option('datadir') / 'singularity' / 'capabilities'
)

install_data('data/share-targets/dev.sinty.lettere.send.ini',
  install_dir: get_option('datadir') / 'singularity' / 'share-targets'
)

install_data('data/icons/dev.sinty.lettere.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

mail_test = executable('lettere-test',
  core_sources + files('tests/mail_test.vala'),
  dependencies: core_deps,
)
test('lettere', mail_test, args: [meson.current_source_dir() / 'tests' / 'fixtures'])

backend_test = executable('lettere-backend-test',
  core_sources + files('tests/backend_test.vala'),
  dependencies: core_deps,
)
test('lettere-backends', backend_test, args: [meson.current_source_dir() / 'tests' / 'api_mock.py'], timeout: 120)

executable('lettere-inspect',
  core_sources + files('tests/inspect.vala'),
  dependencies: core_deps,
)

crypto_test = executable('lettere-crypto-test',
  core_sources + files('tests/crypto_test.vala'),
  dependencies: core_deps,
)
test('lettere-crypto', crypto_test, timeout: 180)

notification_test = executable('lettere-notification-test',
  files('src/notifications.vala', 'tests/notification_test.vala'),
  dependencies: [dependency('gio-2.0'), gee_dep, gtk_dep, gst_dep, libsingularity_dep],
)
test('lettere-notifications', find_program('dbus-run-session'),
  args: ['--', notification_test, meson.current_source_dir() / 'data'],
  env: ['GSETTINGS_BACKEND=memory'],
)

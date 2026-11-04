// ============================================================================
//  NAS Uploader — your settings. Edit the values below, save, then reload the
//  extension (chrome://extensions → NAS Uploader → reload icon).
// ============================================================================
//
//  SECURITY: anyone who can use this Chrome profile can use these credentials.
//  Use a NAS account that can only write to the shared folder you upload into,
//  and never commit your real password to a public repository.

export const CONFIG = {
  // The WebDAV address of your NAS as reachable from the internet. Examples:
  //   Synology (WebDAV Server package, HTTPS):  'https://mynas.synology.me:5006/'
  //   QNAP (WebDAV over HTTPS):                 'https://mynas.myqnapcloud.com:8081/'
  //   TrueNAS / Apache / other WebDAV:          'https://nas.example.com/webdav/'
  //   Nextcloud:                                'https://cloud.example.com/remote.php/dav/files/USERNAME/'
  serverUrl: 'https://your-nas.example.com:5006/',

  username: 'your-nas-username',

  // Put the password here to have it built in. Leave it as '' to be asked for it
  // once per browser session instead (it is then kept in memory only).
  password: 'your-nas-password',

  // Folder that opens first, e.g. '/home' or '/Backups'. '/' is the WebDAV root.
  startFolder: '/',

  // Files uploaded at the same time (1–6). 3 is a good default.
  parallelUploads: 3,
};

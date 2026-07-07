// JXA: lê o status REAL de upload iCloud de cada arquivo passado como argumento.
// Usa NSURLUbiquitousItemIsUploadedKey (não há CLI confiável p/ isso).
// Uso:  osascript -l JavaScript icloud-upload-status.js <path1> <path2> ...
// Saída: JSON array [{uploaded, uploading, error}] na mesma ordem dos paths.
ObjC.import('Foundation');
function run(argv) {
  var out = [];
  for (var i = 0; i < argv.length; i++) {
    var url = $.NSURL.fileURLWithPath(argv[i]);
    var vUp = Ref(), vIng = Ref(), vErr = Ref();
    url.getResourceValueForKeyError(vUp,  $.NSURLUbiquitousItemIsUploadedKey,  null);
    url.getResourceValueForKeyError(vIng, $.NSURLUbiquitousItemIsUploadingKey, null);
    url.getResourceValueForKeyError(vErr, $.NSURLUbiquitousItemUploadingErrorKey, null);
    var er = ObjC.unwrap(vErr[0]);
    out.push({
      uploaded:  ObjC.unwrap(vUp[0])  === true,
      uploading: ObjC.unwrap(vIng[0]) === true,
      error:     (er !== null && er !== undefined),
    });
  }
  return JSON.stringify(out);
}

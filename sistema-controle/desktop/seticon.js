const ResEdit = require('resedit'); const fs = require('fs');
const exePath = process.argv[2], icoPath = process.argv[3];
const exe = ResEdit.NtExecutable.from(fs.readFileSync(exePath), { ignoreCert: true });
const res = ResEdit.NtExecutableResource.from(exe);
const ico = ResEdit.Data.IconFile.from(fs.readFileSync(icoPath));
const groups = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries);
const id = groups.length ? groups[0].id : 1, lang = groups.length ? groups[0].lang : 1033;
ResEdit.Resource.IconGroupEntry.replaceIconsForResource(res.entries, id, lang, ico.icons.map(i => i.data));
const vi = ResEdit.Resource.VersionInfo.fromEntries(res.entries)[0];
if (vi) {
  vi.setStringValues({ lang: 1033, codepage: 1200 }, { ProductName: 'RL Motoboy', FileDescription: 'RL Motoboy - Controle Logístico', CompanyName: 'RL Motoboy Entregas Rápidas', LegalCopyright: 'RL Motoboy Entregas Rápidas', OriginalFilename: 'RL Motoboy.exe', InternalName: 'RL Motoboy' });
  vi.setFileVersion(1, 0, 0, 0); vi.setProductVersion(1, 0, 0, 0); vi.outputToResourceEntries(res.entries);
}
res.outputResource(exe);
fs.writeFileSync(exePath, Buffer.from(exe.generate()));
console.log('icone ok, grupos', groups.length);

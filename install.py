from pathlib import Path
import shutil, plistlib, subprocess, os, datetime
home=Path.home()
support=home/'Library/Application Support/KeyboardAutoLang'
app=home/'Applications/Keyboard AutoLang.app'
source=Path(__file__).resolve().parent
(home/'Library/LaunchAgents').mkdir(parents=True,exist_ok=True)
agent=home/'Library/LaunchAgents/local.keyboardautolang.plist'
# Check and build before changing an existing installation. Never install tools automatically.
compiler=subprocess.run(['/usr/bin/xcrun','--find','swiftc'],capture_output=True,text=True)
if compiler.returncode:
 raise SystemExit('Apple Swift compiler is required. No tools have been installed.')
subprocess.run([compiler.stdout.strip(),'-O','-swift-version','5','-framework','AppKit','-framework','Carbon',str(source/'main.swift'),str(source/'Panel.swift'),'-o',str(source/'KeyboardAutoLang')],check=True)
backup=support/('backup-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
backup.mkdir(parents=True,exist_ok=True)
if app.exists(): shutil.copytree(app,backup/'Keyboard AutoLang.app')
for p in [agent,support/'KeyboardAutoLang',support/'KeyboardAutoLang.swift', support/'rules.json']:
 if p.exists(): shutil.copy2(p,backup/p.name)
subprocess.run(['/bin/launchctl','bootout',f'gui/{os.getuid()}/local.keyboardautolang'],capture_output=True)
(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
exe=app/'Contents/MacOS/KeyboardAutoLang'
shutil.copy2(source/'KeyboardAutoLang',exe)
exe.chmod(0o755)
info={'CFBundleIdentifier':'local.keyboardautolang','CFBundleName':'Keyboard AutoLang','CFBundleDisplayName':'Keyboard AutoLang','CFBundleExecutable':'KeyboardAutoLang','CFBundlePackageType':'APPL','CFBundleVersion':'5','CFBundleShortVersionString':'2.3','CFBundleIconFile':'AppIcon','LSUIElement':True,'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'27.0'}
(app/'Contents/Resources').mkdir(parents=True,exist_ok=True)
shutil.copy2(source/'AppIcon.icns',app/'Contents/Resources/AppIcon.icns')
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','local.keyboardautolang',str(app)],check=True)
for name in ['main.swift','Panel.swift']:
 shutil.copy2(source/name,support/name)
shutil.copy2(exe,support/'KeyboardAutoLang')
config={'Label':'local.keyboardautolang','ProgramArguments':[str(exe)],'RunAtLoad':True,'ProcessType':'Interactive','StandardErrorPath':str(support/'agent.log')}
with agent.open('wb') as f: plistlib.dump(config,f)
subprocess.run(['/usr/bin/plutil','-lint',str(agent)],check=True)
subprocess.run(['/bin/launchctl','bootstrap',f'gui/{os.getuid()}',str(agent)],check=True)
# Refresh Finder's cached bundle icon after copying/signing the resources.
app.touch()
registrar=Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
if registrar.exists():
 subprocess.run([str(registrar),'-f',str(app)],check=False)
print(f'Installed: {app}\nBackup: {backup}')

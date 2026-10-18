#!/usr/bin/env python3
"""Export a public host project, build its unsigned shell, and pack locally.

export and pack use private prepared game data. build needs only the exported
source tree and Xcode; it never receives game files or credentials.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TARGET = json.loads((ROOT / 'config/iphone13pro.json').read_text())
TITLE = TARGET['title_id']
CONTRACT = 'config/actions-host.json'
WORKFLOW = '.github/workflows/build-silksong-host.yml'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def outside(path):
    path = Path(path).expanduser().resolve()
    if path == ROOT or ROOT in path.parents or path in ROOT.parents:
        raise ValueError('Output must be outside the source repository.')
    return path


def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def chain_of(profile):
    match = re.search(r'^#define DMSH_CHAIN "([0-9a-f]{12})"$',
                      (profile / 'dmsh_chain.h').read_text(), re.M)
    if not match:
        raise ValueError('Missing or invalid prepared shader-chain header.')
    return match[1]


def profile_hashes(profile):
    return {name: sha(profile / name) for name in
            ('game.tsv', 'shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv')}


def export_project(args):
    from prepare_silksong import prepared, private_work, shader_audit, snapshot
    work = private_work(args.work)
    prepared(work)
    dest = outside(args.out)
    if dest.exists():
        raise ValueError('Export destination already exists; choose a fresh directory.')
    # Recompute the chain with current source and the prepared tool fingerprints.
    runtime = snapshot(work, 'runtime-actions-check')
    profile = runtime / 'dm/games' / TITLE
    old_profile = work / 'runtime/dm/games' / TITLE
    for name in ('dmsh_chain.h', 'c1_full.tsv'):
        shutil.copy2(old_profile / name, profile / name)
    shutil.copy2(work / 'runtime/dm/gfx/tools/dmsh_chain.lock', runtime / 'dm/gfx/tools/dmsh_chain.lock')
    env = dict(os.environ, GAME=TITLE, DM_GAME=TITLE, PYTHONDONTWRITEBYTECODE='1')
    for key in ('DM_GAMES_DIR', 'XLATE_DEBUG', 'XLATE_REDUCED'):
        env.pop(key, None)
    chain = chain_of(profile)
    actual = subprocess.check_output([sys.executable, runtime / 'dm/gfx/tools/dmsh_chain.py'], env=env, text=True).strip()
    if actual != chain:
        raise ValueError('Prepared shaders differ from current source; run prepare_silksong.py finish.')
    audit = shader_audit(profile, work / 'shader-source', work / 'shader-source-ios', chain, True)
    dest.mkdir(parents=True)
    # Allowlist compiler inputs. No translator binaries, extracted shader code,
    # shader tables, rewritten modules, fonts, game data or nested Git histories.
    suffixes = {'.c', '.h', '.m', '.S', '.inc', '.hpp'}
    names = {'Makefile', 'LICENSE', 'COPYING', 'PATENTS', 'AUTHORS'}
    for directory in ('dm/host', 'dm/gfx', 'dm/third_party', 'dm/ios/Sources'):
        for source in sorted((ROOT / 'nxnative' / directory).rglob('*')):
            relative = source.relative_to(ROOT / 'nxnative')
            if any(part in ('tools', 'tests', 'gen', 'Gen', 'obj', 'bin', '.git') for part in relative.parts):
                continue
            if source.is_file() and (source.suffix in suffixes or source.name in names
                                     or source.name.startswith(('LICENSE', 'COPYING'))):
                target = dest / 'nxnative' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
    copies = {
        ROOT / 'scripts/silksong_actions.py': dest / 'scripts/silksong_actions.py',
        ROOT / WORKFLOW: dest / WORKFLOW,
        ROOT / 'config/iphone13pro.json': dest / 'config/iphone13pro.json',
        ROOT / 'nxnative/dm/games/game.py': dest / 'nxnative/dm/games/game.py',
        ROOT / 'nxnative/dm/ios/tools/gen_build.py': dest / 'nxnative/dm/ios/tools/gen_build.py',
        profile / 'game.tsv': dest / 'nxnative/dm/games' / TITLE / 'game.tsv',
        profile / 'dmsh_chain.h': dest / 'nxnative/dm/games' / TITLE / 'dmsh_chain.h',
    }
    for source in (ROOT / 'nxnative').glob('LICENSE*'):
        copies[source] = dest / 'nxnative' / source.name
    for source, target in copies.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    (dest / '.gitignore').write_text('build/\n__pycache__/\n*.ipa\n*.keys\n*.nsp\n*.nsz\n*.nca\n*.framework/\n*.metallib\n**/Gen/\n**/gen/\n**/*.xcodeproj/\n')
    (dest / 'README.md').write_text(
        '# Silksong iOS host build\n\nExperimental unsigned native host for iPhone 13 Pro (A15), iOS 26+.\n'
        'Use Actions → Build Silksong iOS host → Run workflow in a public repository.\n'
        'Download silksong-ios-host, extract it, then use the original WSL ns2app project:\n\n'
        '```sh\npython3 scripts/silksong_actions.py pack --work /path/to/private-work --host /path/to/host.zip\n```\n\n'
        'This repository and artifact contain no game code, game resources, keys or translated game shaders.\n'
        'The host alone cannot launch the game. Game data is added locally and the user signs/sideloads the result.\n'
        'Device compatibility and the Unity VR geometry shader remain unverified.\n'
        'Runtime sources derive from https://github.com/seedds/nxnative and BC decoding from '
        'https://github.com/seedds/d2r-mobile; source license notices are retained.\n')
    files = {str(p.relative_to(dest)): sha(p) for p in sorted(dest.rglob('*')) if p.is_file()}
    contract = {'schema': 1, 'target': TARGET, 'shader_chain': chain, 'shader_mode': 'device-source-compilation',
                'profile_sha256': profile_hashes(profile), 'files_sha256': files,
                'unsupported_entry_points': audit['unsupported_entry_points']}
    save(dest / CONTRACT, contract)
    save(work / 'actions-host-contract.json', contract)
    save(work / 'actions-export.json', {'status': 'exported-not-built', 'directory': str(dest),
                                      'file_count': len(files) + 1, 'contract_sha256': sha(dest / CONTRACT)})
    print(f'Public host project: {dest}\nFiles: {len(files) + 1}; shader chain: {chain}; no app compiled.')


def verified_contract():
    contract = json.loads((ROOT / CONTRACT).read_text())
    if contract.get('schema') != 1 or contract.get('target') != TARGET:
        raise ValueError('Unsupported host contract or target.')
    for name, expected in contract['files_sha256'].items():
        path = ROOT / name
        if not path.is_file() or path.is_symlink() or sha(path) != expected:
            raise ValueError(f'Exported build input changed: {name}. Re-export after editing.')
    return contract


def macho(path, expected_type):
    with path.open('rb') as stream:
        data = stream.read(32)
    if len(data) < 32:
        raise ValueError(f'Truncated Mach-O: {path.name}')
    magic, cpu, _, file_type = struct.unpack_from('<IIII', data)
    if (magic, cpu, file_type) != (0xfeedfacf, 0x100000c, expected_type):
        raise ValueError(f'Expected arm64 Mach-O type {expected_type}: {path.name}')


def build_host(args):
    contract = verified_contract()
    output = Path(args.out).expanduser().resolve()
    if output == ROOT or output in ROOT.parents or (ROOT / 'nxnative') == output or (ROOT / 'nxnative') in output.parents:
        raise ValueError('Choose a separate build output directory.')
    if output.exists():
        raise ValueError('Build output already exists; choose a fresh directory.')
    output.mkdir(parents=True)
    runtime = output / 'runtime'
    shutil.copytree(ROOT / 'nxnative', runtime)
    ios = runtime / 'dm/ios'
    gen = ios / 'Gen'
    env = dict(os.environ, GAME=TITLE, DM_GAME=TITLE, PYTHONDONTWRITEBYTECODE='1')
    env.pop('DM_GAMES_DIR', None)
    if args.make:
        env['PATH'] = str(Path(args.make).resolve().parent) + os.pathsep + env.get('PATH', '')
    with (output / 'source-list.log').open('w') as log:
        run([sys.executable, ios / 'tools/gen_build.py', runtime / 'dm/host', gen], env=env, stdout=log)
    config = (output / 'source-list.log').read_text()
    config += '\nOTHER_LDFLAGS = $(inherited) $(DM_FRAMEWORKS) -framework UIKit -framework Foundation -framework AVFAudio -framework GameController -framework CoreText\n'
    (gen / 'dm.xcconfig').write_text(config)
    properties = {
        'CFBundleDisplayName': TARGET['game'], 'CFBundleShortVersionString': TARGET['version'],
        'CFBundleVersion': TARGET['version'], 'UIFileSharingEnabled': True,
        'LSSupportsOpeningDocumentsInPlace': True, 'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
        'UIRequiresFullScreen': True, 'UIStatusBarHidden': True, 'UIViewControllerBasedStatusBarAppearance': False,
        'UIRequiredDeviceCapabilities': ['arm64', 'metal'], 'LSSupportsGameMode': True,
        'CADisableMinimumFrameDurationOnPhone': True, 'GCSupportsControllerUserInteraction': True,
        'GCSupportedGameControllers': [{'ProfileName': 'ExtendedGamepad'}],
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {
            'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'SceneDelegate'}]}}}
    settings = {'PRODUCT_BUNDLE_IDENTIFIER': f'org.nxnative.{TITLE.lower()}', 'PRODUCT_NAME': 'DmIOS',
                'TARGETED_DEVICE_FAMILY': '1', 'ARCHS': 'arm64', 'ONLY_ACTIVE_ARCH': 'NO',
                'GCC_C_LANGUAGE_STANDARD': 'gnu11', 'CLANG_ENABLE_OBJC_ARC': 'YES',
                'GCC_PREPROCESSOR_DEFINITIONS': ['$(inherited)', 'DM_SHELL=1'],
                'OTHER_CFLAGS': '$(inherited) -mcpu=apple-a15', 'CODE_SIGNING_ALLOWED': 'NO',
                'CODE_SIGNING_REQUIRED': 'NO', 'CODE_SIGN_IDENTITY': '', 'ENABLE_BITCODE': 'NO',
                'DEBUG_INFORMATION_FORMAT': 'dwarf', 'ASSETCATALOG_COMPILER_APPICON_NAME': '',
                'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks'}
    project = {'name': 'SilksongHost', 'options': {'deploymentTarget': {'iOS': TARGET['deployment_minimum']}},
               'configFiles': {'Release': 'Gen/dm.xcconfig', 'Debug': 'Gen/dm.xcconfig'},
               'targets': {'DmIOS': {'type': 'application', 'platform': 'iOS',
                   'sources': ['Sources', 'Gen/src', {'path': 'Gen/main/main.c', 'compilerFlags': '-Dmain=dm_main'}],
                   'info': {'path': 'Gen/Info.plist', 'properties': properties}, 'settings': settings}}}
    save(ios / 'project.json', project)
    source_count = len(list((gen / 'src').iterdir())) + 1 + sum(p.suffix in ('.m', '.c', '.S') for p in (ios / 'Sources').iterdir())
    save(output / 'build-plan.json', {'status': 'staged-not-compiled', 'source_count': source_count,
                                     'shader_chain': contract['shader_chain'], 'project': str(ios / 'project.json')})
    if args.stage_only:
        print(f'Staged {source_count} source files; no Apple build executed.')
        return
    if sys.platform != 'darwin':
        raise ValueError('build requires macOS/Xcode; use the GitHub Actions workflow.')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
    if int(sdk.split('.')[0]) < 26:
        raise ValueError(f'iOS 26+ SDK required for Metal 4; selected SDK is {sdk}.')
    run(['xcodegen', 'generate', '--spec', 'project.json'], cwd=ios, env=env)
    with (output / 'xcodebuild.log').open('w') as log:
        run(['xcodebuild', '-project', 'SilksongHost.xcodeproj', '-scheme', 'DmIOS', '-configuration', 'Release',
             '-destination', 'generic/platform=iOS', '-derivedDataPath', output / 'DerivedData',
             'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'build'],
            cwd=ios, env=env, stdout=log, stderr=subprocess.STDOUT)
    app = output / 'DerivedData/Build/Products/Release-iphoneos/DmIOS.app'
    macho(app / 'DmIOS', 2)
    app_files = sorted(p for p in app.rglob('*') if p.is_file())
    if any(p.is_symlink() for p in app.rglob('*')):
        raise ValueError('Unexpected symlink in host app.')
    allowed = {'DmIOS', 'Info.plist', 'PkgInfo'}
    if {str(p.relative_to(app)) for p in app_files} - allowed:
        raise ValueError('Unexpected host resources; refusing to publish artifact.')
    artifact = dict(contract, status='unsigned-host-not-device-tested', sdk_version=sdk,
                    shell_files_sha256={f'Payload/DmIOS.app/{p.relative_to(app)}': sha(p) for p in app_files})
    with zipfile.ZipFile(output / 'host.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.writestr('host.json', json.dumps(artifact, indent=2) + '\n')
        for path in app_files:
            archive.write(path, f'Payload/DmIOS.app/{path.relative_to(app)}')
    save(output / 'host-build.json', artifact)
    print(f'Unsigned host artifact: {output / "host.zip"}; no game data included.')


def extract_host(archive_path, dest, expected):
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or 'host.json' not in names:
            raise ValueError('Invalid host archive entries.')
        if any(i.file_size > 256 * 1024 * 1024 for i in archive.infolist()):
            raise ValueError('Unexpectedly large host archive entry.')
        contract = json.loads(archive.read('host.json'))
        if any(contract.get(key) != value for key, value in expected.items()):
            raise ValueError('Host does not match the local exported project; rebuild from the matching export.')
        hashes = contract.get('shell_files_sha256', {})
        if contract.get('status') != 'unsigned-host-not-device-tested' or set(names) != {'host.json', *hashes}:
            raise ValueError('Unexpected content in host artifact.')
        if set(hashes) - {f'Payload/DmIOS.app/{n}' for n in ('DmIOS', 'Info.plist', 'PkgInfo')}:
            raise ValueError('Host archive contains game data or unknown resources.')
        for entry in archive.infolist():
            if entry.filename == 'host.json':
                continue
            relative = PurePosixPath(entry.filename)
            if relative.is_absolute() or '..' in relative.parts or stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('Unsafe host archive path.')
            path = dest.joinpath(*relative.parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as src, path.open('wb') as out:
                shutil.copyfileobj(src, out)
            if sha(path) != hashes[entry.filename]:
                raise ValueError(f'Host artifact checksum mismatch: {entry.filename}')
    app = dest / 'Payload/DmIOS.app'
    macho(app / 'DmIOS', 2)
    (app / 'DmIOS').chmod(0o755)
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleExecutable') != 'DmIOS' or info.get('CFBundleIdentifier') != f'org.nxnative.{TITLE.lower()}':
        raise ValueError('Host bundle identity mismatch.')
    return app, info


def _pack_local(args):
    from prepare_silksong import prepared, private_work, shader_audit
    from fontTools.ttLib import TTFont
    work = private_work(args.work)
    _, extracted, patched = prepared(work)
    contract = json.loads((work / 'actions-host-contract.json').read_text())
    profile = work / 'runtime/dm/games' / TITLE
    if contract['target'] != TARGET or contract['profile_sha256'] != profile_hashes(profile) or contract['shader_chain'] != chain_of(profile):
        raise ValueError('Prepared profile changed after export; export and build the host again.')
    if sha(ROOT / 'nxnative/dm/games' / TITLE / 'game.tsv') != contract['profile_sha256']['game.tsv']:
        raise ValueError('Current game profile changed after export.')
    audit = shader_audit(profile, work / 'shader-source', work / 'shader-source-ios', contract['shader_chain'], True)
    output = outside(args.out) if args.out else work / 'Silksong-iPhone13Pro-unsigned.ipa'
    staging = work / 'actions-package'
    if output == staging or staging in output.parents:
        raise ValueError('IPA output must be outside actions-package.')
    if staging.exists():
        raise ValueError('actions-package already exists; preserve or remove it before a new packaging run.')
    staging.mkdir()
    host_archive = Path(args.host).expanduser().resolve()
    app, info = extract_host(host_archive, staging, contract)
    dm = app / 'dm'
    dm.mkdir()
    for name in TARGET['build_ids']:
        for suffix in ('fixups.tsv', 'gates.tsv', 'params.tsv', 'cuts.tsv', 'obs.tsv'):
            shutil.copy2(patched / f'{name}.{suffix}', dm)
    for name in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv'):
        shutil.copy2(profile / name, dm)
    shutil.copy2(ROOT / 'config/iphone13pro.env', dm / 'env.txt')
    font = dm / 'font'
    font.mkdir()
    with TTFont(Path(args.standard_font).expanduser(), fontNumber=0) as face:
        face.save(font / 'standard.ttf')
    run([sys.executable, ROOT / 'nxnative/dm/tools/make_ext_font.py', font / 'nintendo_ext.ttf', Path(args.letter_font).expanduser()])
    run([sys.executable, ROOT / 'nxnative/dm/tools/guest_dylib.py', patched, app / 'Frameworks', *TARGET['build_ids']])
    macho(app / 'Frameworks/Guest.framework/Guest', 6)
    shutil.copytree(work / 'shader-source-ios' / f"b-{audit['chain']}", app / 'msl' / f"b-{audit['chain']}")
    icon = extracted / 'icon.jpg'
    if icon.is_file():
        from PIL import Image
        with Image.open(icon) as image:
            for scale in (2, 3):
                image.convert('RGB').resize((60 * scale, 60 * scale), Image.Resampling.LANCZOS).save(app / f'AppIcon60x60@{scale}x.png')
        info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}}
        with (app / 'Info.plist').open('wb') as stream:
            plistlib.dump(info, stream)
    report = {'status': 'local-resources-staged', 'target': TARGET, 'shaders': audit,
              'device_tested': False, 'signing': 'user-required', 'app': str(app),
              'romfs': str(extracted / 'RomFS'), 'host_archive_sha256': sha(host_archive)}
    save(work / 'actions-package.json', report)
    if args.stage_only:
        print(f'Local resources staged: {app}; RomFS not copied, no IPA generated.')
        return
    # Stream RomFS into the final Zip64 archive without duplicating its 6+ GiB.
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_suffix(output.suffix + '.partial')
    stored = {'.assets', '.bin', '.bundle', '.dat', '.mp4', '.ress', '.metallib'}
    try:
        with zipfile.ZipFile(partial, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as archive:
            for base, prefix in ((app, 'Payload/DmIOS.app'), (extracted / 'RomFS', 'Payload/DmIOS.app/romfs')):
                for path in sorted(base.rglob('*')):
                    if path.is_file():
                        if path.is_symlink():
                            raise ValueError(f'Unexpected symlink in package: {path.name}')
                        archive.write(path, f'{prefix}/{path.relative_to(base)}',
                                      compress_type=zipfile.ZIP_STORED if path.suffix.lower() in stored else zipfile.ZIP_DEFLATED)
        partial.replace(output)
    finally:
        partial.unlink(missing_ok=True)
    report.update(status='unsigned-ipa-not-device-tested', ipa=str(output), ipa_bytes=output.stat().st_size, ipa_sha256=sha(output))
    save(work / 'actions-package.json', report)
    print(f'Unsigned, not device-tested: {output}')


def pack_local(args):
    from prepare_silksong import private_work
    work = private_work(args.work)
    report_path = work / 'actions-package.json'
    save(report_path, {'status': 'in-progress', 'target': TARGET, 'device_tested': False})
    try:
        _pack_local(args)
    except BaseException as exc:
        report = json.loads(report_path.read_text())
        report.update(status='failed', error=str(exc) or type(exc).__name__)
        save(report_path, report)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export', help='Create a fresh public host-only source directory')
    export.add_argument('--work', default='/tmp/ns2app-silksong')
    export.add_argument('--out', required=True)
    build = commands.add_parser('build', help='Build the exported shell with Xcode')
    build.add_argument('--out', required=True)
    build.add_argument('--stage-only', action='store_true')
    build.add_argument('--make', help='make executable for a Linux source-list rehearsal')
    pack = commands.add_parser('pack', help='Add private game files to a matching downloaded host')
    pack.add_argument('--work', default='/tmp/ns2app-silksong')
    pack.add_argument('--host', required=True, help='host.zip extracted from the Actions artifact download')
    pack.add_argument('--out')
    pack.add_argument('--stage-only', action='store_true')
    pack.add_argument('--standard-font', default='/mnt/c/Windows/Fonts/msyh.ttc')
    pack.add_argument('--letter-font', default='/mnt/c/Windows/Fonts/arialbd.ttf')
    args = parser.parse_args(argv)
    try:
        {'export': export_project, 'build': build_host, 'pack': pack_local}[args.command](args)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile, ImportError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

"""Prepare an ASCII-only build workspace without copying private user data."""
from pathlib import Path
import argparse,json,shutil,tempfile

def prepare(source:Path,android_sdk:Path)->dict:
    source=source.resolve();android_sdk=android_sdk.resolve()
    key=source/'experiments/fqappx-bootstrap/out/fqappx-local.keystore'
    if not key.is_file():raise SystemExit('Original fqappX signing key missing; do not replace it.')
    for abi in ['arm64-v8a','armeabi-v7a']:
        if not (source/f'android/app/src/main/jniLibs/{abi}/libfqapi_core.so').is_file():
            raise SystemExit('Build the Android Rust libraries first.')
    parent=Path(tempfile.gettempdir()).resolve()
    if not str(parent).isascii():raise SystemExit('An ASCII-only system temporary directory is required.')
    stage=Path(tempfile.mkdtemp(prefix='fqappx-build-',dir=parent)).resolve()
    assert stage.is_relative_to(parent) and stage.name.startswith('fqappx-build-')
    ignored=shutil.ignore_patterns('.git','.gradle','.cxx','build','target','__pycache__','*.keystore','keystore.properties','local.properties')
    for name in ['lib','assets','native','android','third_party','scripts','rust','.cargo']:
        if (source/name).exists():shutil.copytree(source/name,stage/name,ignore=ignored)
    for name in ['pubspec.yaml','pubspec.lock','analysis_options.yaml','.metadata','flutter_rust_bridge.yaml']:
        if (source/name).exists():shutil.copyfile(source/name,stage/name)
    target=stage/'experiments/fqappx-bootstrap/out/fqappx-local.keystore'
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(key,target)
    sdk_value=str(android_sdk).replace('\\','\\\\')
    (stage/'android/local.properties').write_text(f'flutter.sdk=S:\\\\\nsdk.dir={sdk_value}\n',encoding='ascii')
    result={'stage':str(stage),'source':str(source),'contains_user_backup':False}
    (source/'build').mkdir(exist_ok=True)
    (source/'build/fqappx-staging.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,required=True);parser.add_argument('--android-sdk',type=Path,required=True)
    args=parser.parse_args();print(json.dumps(prepare(args.source,args.android_sdk)))

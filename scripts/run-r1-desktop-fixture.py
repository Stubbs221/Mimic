#!/usr/bin/env python3
# Created by Василий Маслов on 13.10.2026.
"""Launch only the DEBUG R1 NSApplication fixture, with a separate identity and no user services."""
import argparse
import os
import pathlib
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--inspect', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    app = args.output / 'MimicR1Fixture.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
    (contents / 'Resources').mkdir(exist_ok=True)
    (contents / 'Frameworks').mkdir(exist_ok=True)
    subprocess.run(['/usr/bin/ditto', str(args.products / 'Mimic'), str(contents / 'MacOS/MimicR1Fixture')], check=True)
    for bundle in ('Mimic_Mimic', 'Mimic_MimicCore', 'SwiftTerm_SwiftTerm', 'ZIPFoundation_ZIPFoundation'):
        subprocess.run(['/usr/bin/ditto', str(args.products / (bundle + '.bundle')), str(contents / 'Resources' / (bundle + '.bundle'))], check=True)
    subprocess.run(['/usr/bin/ditto', str(args.products / 'Sparkle.framework'), str(contents / 'Frameworks/Sparkle.framework')], check=True)
    with (contents / 'Info.plist').open('wb') as file:
        plistlib.dump({'CFBundleExecutable': 'MimicR1Fixture', 'CFBundleIdentifier': 'local.vmaslov.MimicR1SurfaceFixture',
                      'CFBundleName': 'Mimic R1 Fixture', 'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication',
                      'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True}, file)
    # Explicit ad hoc signing is confined to this disposable DEBUG app; production retains Developer ID.
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    environment = os.environ.copy()
    environment['MIMIC_R1_FIXTURE_OUTPUT'] = str(args.output.resolve())
    if args.inspect:
        environment['MIMIC_R1_FIXTURE_INSPECT'] = 'true'
    subprocess.run([str(contents / 'MacOS/MimicR1Fixture')], env=environment, check=True, timeout=180)


if __name__ == '__main__':
    main()

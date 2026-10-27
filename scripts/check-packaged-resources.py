#!/usr/bin/env python3
# Created by Василий Маслов on 13.10.2026.
"""Reject release SwiftPM accessors and qualify relocated app/helper resources offline."""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import tempfile


def stage_project_bundle(root, products, destination, target):
    """Copy only declared resources; incremental SwiftPM bundles may retain deleted private files."""
    source = root / 'Sources' / target / 'Resources'
    bundle = products / ('Mimic_' + target + '.bundle')
    output = destination / bundle.name
    resources = {}
    for path in sorted(source.rglob('*')):
        if not path.is_file() or path.name == '.DS_Store':
            continue
        if path.is_symlink():
            raise RuntimeError(f'Symlink resource is unsupported: {path}')
        relative = path.relative_to(source)
        locale = next((index for index, part in enumerate(relative.parts) if part.endswith('.lproj')), None)
        packaged = pathlib.Path(*relative.parts[locale:]) if locale is not None else pathlib.Path(path.name)
        if packaged in resources:
            raise RuntimeError(f'Duplicate packaged resource: {packaged}')
        resources[packaged] = path
    for packaged in [pathlib.Path('Info.plist'), *resources]:
        if not (bundle / packaged).is_file() or (bundle / packaged).is_symlink():
            raise RuntimeError(f'Missing or invalid declared resource: {bundle / packaged}')
    output.mkdir(parents=True, exist_ok=False)
    for packaged in [pathlib.Path('Info.plist'), *resources]:
        target_path = output / packaged
        target_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(bundle / packaged, target_path)


def check_sources(root):
    """Generated Bundle.module is allowed only behind a positive DEBUG guard."""
    failures = []
    for source in (root / 'Sources').rglob('*.swift'):
        guards = []
        for number, line in enumerate(source.read_text().splitlines(), 1):
            code = line.split('//', 1)[0].strip()
            if code.startswith('#if '):
                guards.append(code == '#if DEBUG')
            elif code.startswith(('#else', '#elseif')) and guards:
                guards[-1] = False
            elif code.startswith('#endif') and guards:
                guards.pop()
            if re.search(r'\b(?:NS)?Bundle\s*\.\s*module\b', code) and not any(guards):
                failures.append(f'{source.relative_to(root)}:{number}: release Bundle.module; use the packaged resource resolver')
    if failures:
        raise RuntimeError('\n'.join(failures))


def check_app(app):
    """Move a copy away from build paths, then probe app and MCP helper before deployment."""
    required = ('Mimic_Mimic', 'Mimic_MimicCore', 'Mimic_MimicMCP', 'SwiftTerm_SwiftTerm', 'ZIPFoundation_ZIPFoundation')
    for name in required:
        if not (app / 'Contents/Resources' / (name + '.bundle')).is_dir():
            raise RuntimeError(f'Missing packaged resource bundle: {name}')
    with tempfile.TemporaryDirectory(prefix='MimicResourceQualification-') as directory:
        relocated = pathlib.Path(directory) / 'Mimic.app'
        subprocess.run(['/usr/bin/ditto', str(app), str(relocated)], check=True)
        checks = {}
        for executable in ('MacOS/Mimic', 'Helpers/MimicMCP'):
            result = subprocess.run([str(relocated / 'Contents' / executable), '--check-resources'], check=True,
                                    capture_output=True, text=True, timeout=30)
            values = json.loads(result.stdout)
            if not values or not all(value is True for value in values.values()):
                raise RuntimeError(f'{executable}: incomplete packaged resources: {values}')
            checks[executable] = values
        print(json.dumps(checks, ensure_ascii=False, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', type=pathlib.Path)
    parser.add_argument('--app', type=pathlib.Path)
    parser.add_argument('--stage-products', type=pathlib.Path)
    parser.add_argument('--destination', type=pathlib.Path)
    args = parser.parse_args()
    if not args.sources and not args.app:
        parser.error('Specify --sources and/or --app')
    if args.sources:
        check_sources(args.sources)
    if args.stage_products or args.destination:
        if not args.sources or not args.stage_products or not args.destination:
            parser.error('Staging requires --sources, --stage-products and --destination')
        for target in ('Mimic', 'MimicCore', 'MimicMCP'):
            stage_project_bundle(args.sources, args.stage_products, args.destination, target)
    if args.app:
        check_app(args.app)


if __name__ == '__main__':
    main()

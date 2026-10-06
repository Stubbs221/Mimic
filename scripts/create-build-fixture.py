#!/usr/bin/env python3
# Created by Василий Маслов on 04.10.2026.
"""Generate a minimal simulator-only workspace for explicit Mimic acceptance. Never bootstraps ios3."""
import plistlib
import subprocess
import sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
if root.exists(): raise SystemExit('Choose a new empty fixture directory')
app=root/'App';project=app/'App.xcodeproj';workspace=app/'App.xcworkspace'
project.mkdir(parents=True);workspace.mkdir()
(root/'bootstrap.sh').write_text('#!/bin/sh\n# Created by Василий Маслов on 04.10.2026.\n# Fixture only; never invoked by build acceptance.\nexit 99\n')
(root/'utils.sh').write_text('#!/bin/sh\n# Created by Василий Маслов on 04.10.2026.\n# Fixture only.\nprintf "LEGACY FIXTURE\\n"\n')
(root/'utils.sh').chmod(0o700)
(app/'Value.swift').write_text('// Created by Василий Маслов on 04.10.2026.\nimport Foundation\nfunc mimicFixtureValue() -> Int { 42 }\n')
(app/'FixtureTests.swift').write_text('// Created by Василий Маслов on 04.10.2026.\nimport XCTest\nfinal class FixtureTests: XCTestCase { func testValue() { XCTAssertEqual(mimicFixtureValue(), 42) } }\n')
workspace.joinpath('contents.xcworkspacedata').write_text('<?xml version="1.0"?><!-- Created by Василий Маслов on 04.10.2026. --><Workspace version="1.0"><FileRef location="group:App.xcodeproj"/></Workspace>\n')
objects={};counter=0

def obj(isa,**fields):
 global counter
 counter+=1;key=f'{counter:024X}';objects[key]=dict(isa=isa,**fields);return key

def configuration(name,**settings):return obj('XCBuildConfiguration',name=name,buildSettings=settings)
def configs(settings):return obj('XCConfigurationList',buildConfigurations=[configuration(n,**settings) for n in ['Debug','Release']],defaultConfigurationIsVisible='0',defaultConfigurationName='Debug')
value=obj('PBXFileReference',lastKnownFileType='sourcecode.swift',path='Value.swift',sourceTree='<group>')
tests=obj('PBXFileReference',lastKnownFileType='sourcecode.swift',path='FixtureTests.swift',sourceTree='<group>')
framework=obj('PBXFileReference',explicitFileType='wrapper.framework',path='Fixture.framework',sourceTree='BUILT_PRODUCTS_DIR')
bundle=obj('PBXFileReference',explicitFileType='wrapper.cfbundle',path='FixtureTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
products=obj('PBXGroup',children=[framework,bundle],name='Products',sourceTree='<group>')
main=obj('PBXGroup',children=[value,tests,products],sourceTree='<group>')
def sources(files):return obj('PBXSourcesBuildPhase',buildActionMask='2147483647',files=[obj('PBXBuildFile',fileRef=f) for f in files],runOnlyForDeploymentPostprocessing='0')
common=dict(ALWAYS_SEARCH_USER_PATHS='NO',SDKROOT='iphonesimulator',SUPPORTED_PLATFORMS='iphonesimulator',IPHONEOS_DEPLOYMENT_TARGET='18.0',SWIFT_VERSION='5.0',CODE_SIGNING_ALLOWED='NO',GENERATE_INFOPLIST_FILE='YES',TARGETED_DEVICE_FAMILY='1,2')
lib=obj('PBXNativeTarget',name='Fixture',productName='Fixture',productReference=framework,productType='com.apple.product-type.framework',buildConfigurationList=configs(dict(common,PRODUCT_BUNDLE_IDENTIFIER='example.test.MimicFixture',PRODUCT_NAME='$(TARGET_NAME)',DEFINES_MODULE='YES')),buildPhases=[sources([value])],buildRules=[],dependencies=[])
test=obj('PBXNativeTarget',name='FixtureTests',productName='FixtureTests',productReference=bundle,productType='com.apple.product-type.bundle.unit-test',buildConfigurationList=configs(dict(common,PRODUCT_BUNDLE_IDENTIFIER='example.test.MimicFixtureTests',PRODUCT_NAME='$(TARGET_NAME)')),buildPhases=[sources([value,tests])],buildRules=[],dependencies=[])
proj=obj('PBXProject',attributes=dict(LastUpgradeCheck='2600'),buildConfigurationList=configs(common),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[lib,test])
(project/'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=proj)))
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True)
def ref(target,name,product):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:App.xcodeproj"/>'
(schemes/'Fixture.xcscheme').write_text(f'''<?xml version="1.0"?>
<!-- Created by Василий Маслов on 04.10.2026. -->
<Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="NO" buildForAnalyzing="YES">{ref(lib,'Fixture','Fixture.framework')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ref(test,'FixtureTests','FixtureTests.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test,'FixtureTests','FixtureTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug"/><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/></Scheme>\n''')
for args in [['init','-q'],['add','.'],['-c','user.name=Mimic Fixture','-c','user.email=mimic@example.test','commit','-qm','Isolated acceptance fixture']]:subprocess.run(['/usr/bin/git','-C',str(root),*args],check=True)
print(root)

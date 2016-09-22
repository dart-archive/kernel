#!/usr/bin/env dart
// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:kernel/kernel.dart';
import 'package:kernel/target/vm.dart';
import 'package:kernel/target/targets.dart';
import 'package:package_config/discovery.dart';
import 'package:package_config/packages.dart';

ArgParser parser = new ArgParser()
  ..addOption('sdk', help: 'Path to the SDK checkout');

final String usage = """
Usage: regenerate_dill_files --sdk <path to SDK checkout>

Recompiles all the .dill files that are under version control.
""";

void compile(
    {String dartFile,
    String sdk,
    String packageRoot,
    String output,
    bool strongMode: false}) {
  String strongMessage = strongMode ? '(strong mode)' : '';
  if (!new Directory(sdk).existsSync()) {
    print('SDK not found: $sdk');
    exit(1);
  }
  print('Compiling $dartFile $strongMessage');
  Packages packages =
      getPackagesDirectory(new Uri(scheme: 'file', path: packageRoot));
  var repo = new Repository(sdk: sdk, packages: packages);
  var program = loadProgramFromDart(dartFile, repo, strongMode: strongMode);
  new VmTarget(new TargetFlags(strongMode: strongMode))
      .transformProgram(program);
  writeProgramToBinary(program, output);
}

final List<String> buildDirs = <String>[
  'DebugX64',
  'DebugIA32',
  'ReleaseX64',
  'ReleaseIA32'
];

String getNewestBuildDir(String sdk) {
  var dirs = buildDirs
      .map((name) => new Directory('$sdk/out/$name'))
      .where((dir) => dir.existsSync())
      .toList()
        ..sort((Directory dir1, Directory dir2) =>
            dir1.statSync().modified.compareTo(dir2.statSync().modified));
  if (dirs.isEmpty) {
    print('Could not find a build directory in $sdk/out.\n'
        'Please compile the SDK first.');
    exit(1);
  }
  return dirs.last.path;
}

main(List<String> args) async {
  ArgResults options = parser.parse(args);
  String sdk = options['sdk'];
  if (sdk == null || options.rest.isNotEmpty) {
    print(usage);
    exit(1);
  }
  if (!new Directory(sdk).existsSync()) {
    print('SDK not found: $sdk');
    exit(1);
  }
  String baseDir = path.dirname(path.dirname(Platform.script.toFilePath()));
  Directory.current = baseDir;

  // Compile files in test/data
  String sdkRoot = getNewestBuildDir(sdk) + '/obj/gen/patched_sdk';
  String packageRoot = getNewestBuildDir(sdk) + '/packages';
  String dart2js = '$sdk/pkg/compiler/lib/src/dart2js.dart';
  compile(
      sdk: sdkRoot,
      dartFile: dart2js,
      packageRoot: packageRoot,
      output: 'test/data/dart2js.dill');
  compile(
      sdk: sdkRoot,
      strongMode: true,
      dartFile: dart2js,
      packageRoot: packageRoot,
      output: 'test/data/dart2js-strong.dill');
  compile(
      sdk: sdkRoot,
      dartFile: 'test/data/boms.dart',
      output: 'test/data/boms.dill');
}

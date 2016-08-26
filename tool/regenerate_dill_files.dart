#!/usr/bin/env dart
// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:kernel/kernel.dart';
import 'package:kernel/target/vm.dart';
import '../bin/dartk.dart' as cmd;

ArgParser parser = new ArgParser()
  ..addOption('sdk', help: 'Path to the SDK checkout');

final String usage = """
Usage: regenerate_dill_files --sdk <path to SDK checkout>

Recompiles all the .dill files that are under version control.
""";

void compile({String dartFile, String packageRoot, String output}) {
  print('Compiling $dartFile');
  var repo = new Repository(sdk: cmd.currentSdk(), packageRoot: packageRoot);
  var program = loadProgramFromDart(dartFile, repo);
  new VmTarget().transformProgram(program);
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
  String packageRoot = getNewestBuildDir(sdk) + '/packages';
  compile(
      dartFile: '$sdk/pkg/compiler/lib/src/dart2js.dart',
      packageRoot: packageRoot,
      output: 'test/data/dart2js.dill');
  compile(dartFile: 'test/data/boms.dart', output: 'test/data/boms.dill');

  // Compile type propagation test cases.
  for (var entity
      in new Directory('test/type_propagation/testcases').listSync()) {
    if (entity.path.endsWith('.dart')) {
      String name = path.basename(entity.path);
      name = name.substring(0, name.length - '.dart'.length);
      compile(
          dartFile: entity.path,
          output: 'test/type_propagation/binary/$name.dill');
    }
  }
}

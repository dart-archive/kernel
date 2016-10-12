// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

const int max = 100;

main() {
  var closures = [];
  try { // TODO(ahe): Remove try-catch.
    for (int i = 0; i < max; i++) {
      closures.add(() => i);
    }
  } on String {
    return;
  }
  int sum = 0;
  for (Function f in closures) {
    sum += f();
  }
  // This formula is credited to Gauss. Search for "Gauss adding 1 to 100".
  int expectedSum = (max - 1) * max ~/ 2;
  if (expectedSum != sum) {
    throw new Exception("Unexpected sum = $sum != $expectedSum");
  }
}

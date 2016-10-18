// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

var x = () => "x";

class C {
  final y = () => "y";

  static final z = () => "z";
}

main() {
  if ("x" != x()) throw "x";
  if ("y" != new C().y()) throw "y";
  if ("z" != C.z()) throw "z";
}

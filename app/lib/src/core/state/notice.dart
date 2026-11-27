// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';

/// Tells the user something; with [undo], offers to take it back.
typedef ShowNotice = void Function(String message, {VoidCallback? undo});

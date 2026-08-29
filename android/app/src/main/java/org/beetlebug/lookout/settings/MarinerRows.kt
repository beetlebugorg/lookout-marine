package org.beetlebug.lookout.settings

import org.beetlebug.lookout.ui.SizeRow
import org.beetlebug.lookout.ui.SwitchRow

import androidx.compose.runtime.Composable

// The mariner state bound to the shell's generic rows.
//
// The rows themselves know nothing about S-52: they take a value and a
// callback, which is what lets a plugin's own settings and the charts pane use
// them too. This is the one place that knows a mariner field is an index into a
// flat double[].

/** A flag of the mariner state, as a switch. */
@Composable
internal fun SwitchRow(title: String, m: MarinerState, index: Int) {
    SwitchRow(title, m.flag(index)) { m.setFlag(index, it) }
}

/** A size multiplier of the mariner state, as a slider. */
@Composable
internal fun SizeRow(title: String, m: MarinerState, index: Int) {
    SizeRow(title, m.num(index)) { m.setNum(index, it) }
}

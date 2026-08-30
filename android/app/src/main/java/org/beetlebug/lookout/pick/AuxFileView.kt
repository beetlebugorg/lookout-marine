// A file the chart itself carries — a TXTDSC chart note, a PICREP bridge
// photograph — shown whole. The Android twin of the reference's AuxFileView.
package org.beetlebug.lookout.pick


import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp

@Composable
fun AuxFileDialog(file: AuxFile, onDismiss: () -> Unit) {
    // Decoded by CONTENT, not by the mime string: the engine's mime is a
    // hint, and a picture that will not decode falls through to text, which
    // falls through to the honest sentence.
    val bitmap = remember(file) {
        BitmapFactory.decodeByteArray(file.bytes, 0, file.bytes.size)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(file.name, style = MaterialTheme.typography.titleSmall) },
        text = {
            if (bitmap != null) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = file.name,
                    modifier = Modifier.heightIn(max = 340.dp),
                )
            } else {
                val text = remember(file) {
                    // UTF-8 first; the S-57 era wrote ISO Latin-1, and a
                    // replacement-charactered note is unreadable.
                    val utf8 = file.bytes.toString(Charsets.UTF_8)
                    if ('�' in utf8) file.bytes.toString(Charsets.ISO_8859_1) else utf8
                }
                Text(
                    if (text.isBlank()) "The chart does not carry this file." else text,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .heightIn(max = 340.dp)
                        .verticalScroll(rememberScrollState()),
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

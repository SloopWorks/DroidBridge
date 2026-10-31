package dev.droidbridge.companion

import android.app.Activity
import android.os.Bundle
import android.view.WindowInsets
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Offline license viewer; no external intents, device data or network access. */
class ThirdPartyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val padding = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            view.setPadding(padding + bars.left, bars.top, padding + bars.right, bars.bottom)
            insets
        }
        root.addView(Button(this).apply { text = "Done"; setOnClickListener { finish() } })
        val text = listOf("COMPONENTS.txt", "Apache-2.0.txt", "NOTICE.txt", "zxing-NOTICE.txt", "kotlin-NOTICE.txt").joinToString("\n\n") { name ->
            assets.open("licenses/$name").use { input ->
                val bytes = input.readBytes()
                check(bytes.size <= 65_536)
                bytes.toString(Charsets.UTF_8)
            }
        }
        val body = TextView(this).apply { setText(text); textSize = 16f; setTextIsSelectable(true); setPadding(0, padding, 0, padding) }
        root.addView(ScrollView(this).apply { addView(body) }, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
    }
}

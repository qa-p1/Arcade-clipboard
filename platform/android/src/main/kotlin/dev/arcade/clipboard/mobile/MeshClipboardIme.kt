package dev.arcade.clipboard.mobile

import android.content.Context
import android.graphics.Typeface
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** A text-insertion keyboard that reads only the bounded app-published clip cache. */
class MeshClipboardIme : InputMethodService() {
    private lateinit var store: MobileSharedStore
    private lateinit var list: LinearLayout
    private lateinit var search: EditText
    private lateinit var stateLabel: TextView
    private var history = MobileSharedStore.KeyboardHistory(paused = false, items = emptyList())
    private var secureField = false

    override fun onCreate() {
        super.onCreate()
        store = MobileSharedStore(applicationContext)
    }

    override fun onCreateInputView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(6))
            setBackgroundColor(0xfff6f5f2.toInt())
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(TextView(this).apply {
            text = "Mesh clipboard"
            textSize = 16f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(0xff222321.toInt())
        }, LinearLayout.LayoutParams(0, dp(42), 1f))
        header.addView(Button(this).apply {
            text = "⇄"
            contentDescription = "Switch keyboard"
            setOnClickListener { switchKeyboard() }
        }, LinearLayout.LayoutParams(dp(56), dp(42)))
        root.addView(header)

        search = EditText(this).apply {
            hint = "Search shared clips"
            singleLine = true
            textSize = 15f
            setPadding(dp(12), 0, dp(12), 0)
            addTextChangedListener(SimpleTextWatcher { renderItems() })
        }
        root.addView(search, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(44)))

        stateLabel = TextView(this).apply {
            textSize = 13f
            setTextColor(0xff646761.toInt())
            gravity = Gravity.CENTER
            visibility = View.GONE
        }
        root.addView(stateLabel, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(38)))

        val scroll = ScrollView(this).apply { isFillViewport = false }
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        scroll.addView(list)
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        secureField = info?.let(::isSecureInput) ?: false
        search.setText("")
        history = store.readKeyboardHistory()
        renderItems()
    }

    private fun renderItems() {
        if (!::list.isInitialized || !::stateLabel.isInitialized) return
        list.removeAllViews()
        if (secureField) {
            showState("Clipboard insertion is disabled in secure fields.")
            return
        }
        if (history.paused) {
            showState("Mesh is paused.")
            return
        }
        if (history.needsRefresh) {
            showState("Open Arcade Clipboard to refresh shared clips.")
            return
        }
        val query = if (::search.isInitialized) search.text.toString().trim() else ""
        val matching = history.items.filter { item ->
            query.isEmpty() || item.text.contains(query, ignoreCase = true) ||
                item.sourceName.contains(query, ignoreCase = true)
        }
        if (matching.isEmpty()) {
            showState(if (query.isEmpty()) "No shared clips yet." else "No matching clips.")
            return
        }
        stateLabel.visibility = View.GONE
        matching.forEach { item ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(12), dp(9), dp(12), dp(9))
                background = selectableItemBackground()
                contentDescription = "${item.sourceName}, ${item.text.take(100)}. Tap to insert."
                isFocusable = true
                setOnClickListener { insert(item.text) }
            }
            val preview = TextView(this).apply {
                text = item.text.replace('\n', ' ').take(180)
                maxLines = 2
                textSize = 15f
                setTextColor(0xff252623.toInt())
            }
            val metadata = TextView(this).apply {
                val whenText = if (item.createdAt > 0L) {
                    DateUtils.getRelativeTimeSpanString(
                        item.createdAt,
                        System.currentTimeMillis(),
                        DateUtils.MINUTE_IN_MILLIS,
                    ).toString()
                } else ""
                text = listOf(item.sourceName, whenText).filter(String::isNotBlank).joinToString(" · ")
                textSize = 12f
                setTextColor(0xff696b66.toInt())
            }
            row.addView(preview)
            row.addView(metadata, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(20)))
            list.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { bottomMargin = dp(4) })
        }
    }

    private fun showState(message: String) {
        stateLabel.text = message
        stateLabel.visibility = View.VISIBLE
    }

    private fun insert(text: String) {
        val connection = currentInputConnection
        if (secureField || connection == null) return
        // Do not inspect surrounding text: only insert the user-selected item.
        if (connection.commitText(text, 1)) {
            requestHideSelf(0)
        } else {
            stateLabel.text = "This field can’t accept clipboard text."
            stateLabel.visibility = View.VISIBLE
        }
    }

    private fun switchKeyboard() {
        if (!switchToNextInputMethod(false)) {
            val manager = getSystemService(Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
            manager.showInputMethodPicker()
        }
    }

    private fun isSecureInput(info: EditorInfo): Boolean {
        val variation = info.inputType and InputType.TYPE_MASK_VARIATION
        val inputClass = info.inputType and InputType.TYPE_MASK_CLASS
        return (inputClass == InputType.TYPE_CLASS_TEXT && variation in setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        )) || (inputClass == InputType.TYPE_CLASS_NUMBER &&
            variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)
    }

    private fun selectableItemBackground(): android.graphics.drawable.Drawable? {
        val attributes = intArrayOf(android.R.attr.selectableItemBackground)
        val typedArray = obtainStyledAttributes(attributes)
        return typedArray.getDrawable(0).also { typedArray.recycle() }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}

private class SimpleTextWatcher(private val changed: () -> Unit) : android.text.TextWatcher {
    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = changed()
    override fun afterTextChanged(s: android.text.Editable?) = Unit
}

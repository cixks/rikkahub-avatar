package me.rerere.rikkahub.utils

/**
 * 判断一段文字里有没有角色对话。
 *
 * 只认成对闭合的引号，并且跳过代码/公式，避免把代码里的引号当成台词。
 * 流式输出时引号还没闭合会返回 false，闭合后再变 true，符合直觉。
 */
fun String.containsDialogue(): Boolean {
    val plain = stripNonDialogue()
    for ((open, close) in CJK_QUOTE_PAIRS) {
        if (hasPaired(plain, open, close) { it.isNotBlank() }) return true
    }
    // 英文双引号：要求有中文，或者至少两个字符且含字母（排除 5" 这类尺寸）
    if (hasPaired(plain, '"', '"') { content ->
            content.isNotBlank() && (
                content.any(Char::isCjk) ||
                    (content.length >= 2 && content.any(Char::isLetter))
                )
        }
    ) return true
    // 英文单引号歧义大（don't / it's），只有包着中文才认
    if (hasPaired(plain, '\'', '\'') { it.any(Char::isCjk) }) return true
    return false
}

private val CJK_QUOTE_PAIRS = listOf(
    '「' to '」',
    '『' to '』',
    '“' to '”',
    '‘' to '’',
)

private val FENCE_LINE = Regex("""^ {0,3}(`{3,}|~{3,})""")
private val INLINE_CODE = Regex("""`+[^`\n]*`+""")

/** 去掉代码块和行内代码，剩下的才是可能含对话的正文 */
private fun String.stripNonDialogue(): String {
    val result = StringBuilder()
    var inFence = false
    for (line in lines()) {
        if (FENCE_LINE.containsMatchIn(line)) {
            inFence = !inFence
            continue
        }
        if (!inFence) result.appendLine(line)
    }
    return INLINE_CODE.replace(result.toString(), "")
}

private inline fun hasPaired(
    text: String,
    open: Char,
    close: Char,
    accept: (String) -> Boolean,
): Boolean {
    var index = 0
    while (index < text.length) {
        if (text[index] != open) {
            index++
            continue
        }
        var end = index + 1
        while (end < text.length && text[end] != close) end++
        if (end >= text.length) return false
        if (accept(text.substring(index + 1, end))) return true
        index = end + 1
    }
    return false
}

private fun Char.isCjk(): Boolean =
    this in '\u4E00'..'\u9FFF' ||
        this in '\u3040'..'\u30FF' ||
        this in '\uAC00'..'\uD7AF'

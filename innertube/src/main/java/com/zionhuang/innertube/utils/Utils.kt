package com.zionhuang.innertube.utils

import com.zionhuang.innertube.YouTube
import com.zionhuang.innertube.pages.LibraryPage
import com.zionhuang.innertube.pages.PlaylistPage
import kotlin.jvm.JvmName

@JvmName("completedLibrary")
suspend fun Result<PlaylistPage>.completed(): Result<PlaylistPage> = runCatching {
    val page = getOrThrow()
    val songs = page.songs.toMutableList()
    var continuation = page.songsContinuation
    while (continuation != null) {
        val continuationPage = YouTube.playlistContinuation(continuation).getOrThrow()
        songs += continuationPage.songs
        continuation = continuationPage.continuation
    }
    PlaylistPage(
        playlist = page.playlist,
        songs = songs,
        songsContinuation = null,
        continuation = page.continuation
    )
}

@JvmName("completedPlaylist")
suspend fun Result<LibraryPage>.completed(): Result<LibraryPage> = runCatching {
    val page = getOrThrow()
    val items = page.items.toMutableList()
    var continuation = page.continuation
    while (continuation != null) {
        val continuationPage = YouTube.libraryContinuation(continuation).getOrThrow()
        items += continuationPage.items
        continuation = continuationPage.continuation
    }
    LibraryPage(
        items = items,
        continuation = page.continuation
    )
}

fun ByteArray.toHex(): String =
    joinToString(separator = "") { eachByte -> eachByte.toUByte().toString(16).padStart(2, '0') }

fun sha1(str: String): String {
    val message = str.encodeToByteArray()
    val messageLengthBits = message.size.toLong() * 8
    val paddedLength = ((message.size + 9 + 63) / 64) * 64
    val padded = ByteArray(paddedLength)

    message.copyInto(padded)
    padded[message.size] = 0x80.toByte()
    for (i in 0 until 8) {
        padded[paddedLength - 1 - i] = ((messageLengthBits ushr (i * 8)) and 0xFF).toByte()
    }

    var h0 = 0x67452301
    var h1 = 0xEFCDAB89.toInt()
    var h2 = 0x98BADCFE.toInt()
    var h3 = 0x10325476
    var h4 = 0xC3D2E1F0.toInt()

    val w = IntArray(80)
    var offset = 0
    while (offset < paddedLength) {
        for (i in 0 until 16) {
            val index = offset + i * 4
            w[i] = ((padded[index].toInt() and 0xFF) shl 24) or
                ((padded[index + 1].toInt() and 0xFF) shl 16) or
                ((padded[index + 2].toInt() and 0xFF) shl 8) or
                (padded[index + 3].toInt() and 0xFF)
        }
        for (i in 16 until 80) {
            w[i] = leftRotate(w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16], 1)
        }

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4

        for (i in 0 until 80) {
            val (f, k) = when (i) {
                in 0..19 -> ((b and c) or (b.inv() and d)) to 0x5A827999
                in 20..39 -> (b xor c xor d) to 0x6ED9EBA1
                in 40..59 -> ((b and c) or (b and d) or (c and d)) to 0x8F1BBCDC.toInt()
                else -> (b xor c xor d) to 0xCA62C1D6.toInt()
            }

            val temp = leftRotate(a, 5) + f + e + k + w[i]
            e = d
            d = c
            c = leftRotate(b, 30)
            b = a
            a = temp
        }

        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e
        offset += 64
    }

    return listOf(h0, h1, h2, h3, h4).joinToString(separator = "") {
        (it.toLong() and 0xFFFFFFFFL).toString(16).padStart(8, '0')
    }
}

private fun leftRotate(value: Int, bits: Int): Int =
    (value shl bits) or (value ushr (32 - bits))

fun parseCookieString(cookie: String): Map<String, String> =
    cookie.split("; ")
        .filter { it.isNotEmpty() }
        .associate {
            val (key, value) = it.split("=")
            key to value
        }

fun String.parseTime(): Int? {
    try {
        val parts = split(":").map { it.toInt() }
        if (parts.size == 2) {
            return parts[0] * 60 + parts[1]
        }
        if (parts.size == 3) {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
    } catch (e: Exception) {
        return null
    }
    return null
}

fun isPrivateId(browseId: String): Boolean {
    return browseId.contains("privately")
}
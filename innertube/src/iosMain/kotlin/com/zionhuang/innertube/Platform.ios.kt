package com.zionhuang.innertube

import com.zionhuang.innertube.models.YouTubeClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.*
import io.ktor.client.plugins.*
import io.ktor.client.plugins.compression.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import platform.posix.time

actual class PlatformProxy

@OptIn(ExperimentalSerializationApi::class)
internal actual fun createInnerTubeHttpClient(proxy: PlatformProxy?): HttpClient = HttpClient(Darwin) {
    expectSuccess = true

    install(ContentNegotiation) {
        json(
            Json {
                ignoreUnknownKeys = true
                explicitNulls = false
                encodeDefaults = true
            }
        )
    }

    install(ContentEncoding) {
        gzip(0.9F)
        deflate(0.8F)
    }

    defaultRequest {
        url(YouTubeClient.API_URL_YOUTUBE_MUSIC)
    }
}

internal actual fun defaultCountryCode(): String = "US"

internal actual fun defaultLanguageTag(): String = "en-US"

@OptIn(ExperimentalForeignApi::class)
internal actual fun currentTimeMillis(): Long = time(null).toLong() * 1000L

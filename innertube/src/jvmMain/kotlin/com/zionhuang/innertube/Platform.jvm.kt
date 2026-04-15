package com.zionhuang.innertube

import com.zionhuang.innertube.models.YouTubeClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.*
import io.ktor.client.plugins.*
import io.ktor.client.plugins.compression.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import java.net.Proxy
import java.util.Locale

actual typealias PlatformProxy = Proxy

@OptIn(ExperimentalSerializationApi::class)
internal actual fun createInnerTubeHttpClient(proxy: PlatformProxy?): HttpClient = HttpClient(OkHttp) {
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

    if (proxy != null) {
        engine {
            this.proxy = proxy
        }
    }

    defaultRequest {
        url(YouTubeClient.API_URL_YOUTUBE_MUSIC)
    }
}

internal actual fun defaultCountryCode(): String = Locale.getDefault().country

internal actual fun defaultLanguageTag(): String = Locale.getDefault().toLanguageTag()

internal actual fun currentTimeMillis(): Long = System.currentTimeMillis()

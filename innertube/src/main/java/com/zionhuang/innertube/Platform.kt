package com.zionhuang.innertube

import io.ktor.client.HttpClient

expect class PlatformProxy

internal expect fun createInnerTubeHttpClient(proxy: PlatformProxy?): HttpClient

internal expect fun defaultCountryCode(): String

internal expect fun defaultLanguageTag(): String

internal expect fun currentTimeMillis(): Long

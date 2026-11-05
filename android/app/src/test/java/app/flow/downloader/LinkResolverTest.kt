package app.flow.downloader

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

class LinkResolverTest {
    private class Response(url: String, val status: Int, val location: String?) : HttpURLConnection(URL(url)) {
        var closed = false
        override fun getResponseCode() = status
        override fun getHeaderField(name: String?) = if (name == "Location") location else null
        override fun disconnect() { closed = true }
        override fun connect() { }
        override fun usingProxy() = false
    }

    @Test fun expandsShortLinksAndAlwaysClosesConnection() {
        val response = Response("https://v.douyin.com/test/", 302, "https://www.iesdouyin.com/xg/video/7701276194097028025/?utm_source=copy")
        assertEquals("https://www.douyin.com/video/7701276194097028025", LinkResolver.resolve(response.url.toString()) { response })
        assertTrue(response.closed)
    }
    @Test fun handlesRelativeRedirectsAndCanonicalLinksWithoutExtraRequests() {
        var calls = 0
        val result = LinkResolver.resolve("https://v.douyin.com/test/") { url ->
            calls++
            Response(url, 302, "/share/video/7694479575518022946/")
        }
        assertEquals("https://www.douyin.com/video/7694479575518022946", result); assertEquals(1, calls)
        assertEquals(result, LinkResolver.resolve(result) { error("Unnecessary network request") })
        assertEquals("https://example.org/video.mp4", LinkResolver.resolve("https://example.org/video.mp4") { error("Touched non-Douyin link") })
    }
    @Test fun rejectsOffsiteRedirectsAndLoops() {
        assertThrows(IllegalArgumentException::class.java) {
            LinkResolver.resolve("https://v.douyin.com/test/") { Response(it, 302, "file:///etc/passwd") }
        }
        var calls = 0
        assertThrows(IllegalStateException::class.java) {
            LinkResolver.resolve("https://v.douyin.com/test/") { calls++; Response(it, 302, "/test/") }
        }
        assertEquals(8, calls)
    }
}

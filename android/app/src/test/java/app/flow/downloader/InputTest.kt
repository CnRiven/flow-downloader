package app.flow.downloader

import org.junit.Assert.*
import org.junit.Test

class InputTest {
    @Test fun acceptsOnlyHttpUrls() {
        assertEquals("https://example.com/a?x=1&y=2", Input.validate(" https://example.com/a?x=1&y=2 "))
        for (value in listOf("file:///etc/passwd", "--exec=bad", "hello", "https://")) {
            assertThrows(IllegalArgumentException::class.java) { Input.validate(value) }
        }
    }

    @Test fun extractsUsersDouyinShareTextAndMarkdown() {
        val url = "https://v.douyin.com/Oth-A-XmqqQ/"
        val share = "6.97 复制打开抖音，看看【铁血影视汇的作品】找两千个会英语的！ # 了不起的混剪团 # 共鸣叙... $url :0pm xfo:/ 12/09 L@w.fB"
        assertEquals(url, Input.validate(share))
        assertEquals(url, Input.validate("看看 [$url]($url)"))
        assertEquals(url, Input.validate("复制链接：${url}，看看这个视频。"))
        assertEquals("https://a.com", Input.validate("https://a.com\n--exec=bad"))
    }

    @Test fun normalizesLegacyAndXgRoutesWithoutTouchingOtherHosts() {
        assertEquals("https://www.douyin.com/video/7701276194097028025", Input.validate("https://www.iesdouyin.com/xg/video/7701276194097028025/?app=video_article&timestamp=1793835539"))
        assertEquals("https://www.douyin.com/video/7694479575518022946", Input.validate("https://www.iesdouyin.com/share/video/7694479575518022946/?from_ssr=1"))
        assertEquals("https://www.douyin.com/video/1234", Input.validate("https://www.douyin.com/?modal_id=1234"))
        val fake = "https://douyin.com.example.org/xg/video/1234/"
        assertEquals(fake, Input.validate(fake)); assertFalse(Input.isDouyin(fake))
    }
}

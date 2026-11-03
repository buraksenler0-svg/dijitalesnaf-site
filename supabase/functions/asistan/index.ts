// ═══════════════════════════════════════════════════════════════════════════════════════════
//  Dijital Esnaf AI · "asistan" sunucu fonksiyonu (Supabase Edge Function)
//  AI Asistan ve Kampanyalar bu fonksiyonla çalışır. Claude API anahtarı yalnızca burada durur,
//  hiçbir zaman tarayıcıya gitmez.
//
//  Gerekli gizli anahtar (Edge Functions > Secrets):  ANTHROPIC_API_KEY
//  İsteğe bağlı:  AI_MODEL  (varsayılan: claude-haiku-5-5)
// ═══════════════════════════════════════════════════════════════════════════════════════════

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function yanit(veri: unknown, durum = 200): Response {
  return new Response(JSON.stringify(veri), {
    status: durum,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

const SISTEM_SORU = `Sen "Dijital Esnaf AI" uygulamasının asistanısın. Türkiye'de dükkân işleten esnafa işini yönetmede yardım ediyorsun.

Nasıl cevap verirsin:
- Her zaman Türkçe, sade ve samimi yaz. Teknik terim kullanma; kullanıcıya "sen" diye hitap et.
- Kısa tut: önce doğrudan cevap, gerekirse ardından en fazla 4 madde.
- Rakamları yalnızca aşağıdaki işletme verisinden al, asla uydurma. Tutarları "1.250 TL" biçiminde yaz.
- Veri yoksa ya da sıfırsa bunu açıkça söyle ve o bilgiyi görebilmesi için uygulamada neyi girmesi gerektiğini anlat (örneğin satışları Satış ekranından, giderleri Muhasebe'den girmek).
- Önerilerini veriye dayandır ve nedenini söyle (örneğin "son 30 günde 12 adet sattın, stokta 2 kaldı").
- "Ne almalıyım" sorularında son 30 günlük satış hızına ve mevcut stoka bak; yaklaşık kaç günde biteceğini hesapla.
- Vergi, muhasebe ve hukuk konularında genel bilgi ver; kesin hüküm verme, mali müşavire danışmasını öner.
- Yalnızca bu işletmenin verisini biliyorsun; başka işletmeler hakkında bilgi verme.
- İşletme verisindeki "bugun" alanı bugünün tarihidir.
- İşletme verisinde "erisim_notu" varsa ona kesinlikle uy: soran kişi mağaza müdürü ya da personeldir; ciro, kâr, gelir, gider, kasa ve satış tutarı sorularını tahmin yürütmeden, nazikçe reddet ("Bu bilgiyi görme yetkin yok; işletme sahibine sorabilirsin.") ve stok, ürünler ya da teknik servis konusunda yardım teklif et.`;

const SISTEM_KAMPANYA = `Sen "Dijital Esnaf AI" uygulamasının kampanya asistanısın. Türkiye'deki bir esnafın müşterilerine gönderebileceği kampanya metinlerini hazırlıyorsun.

Kurallar:
- Türkçe, samimi, kısa ve satış odaklı yaz. Kanıtlanamayan iddialardan ("en ucuz", "garantili" gibi) ve yanıltıcı ifadelerden kaçın.
- Fiyat ve indirim bilgisini yalnızca kullanıcının verdiği bilgiden al; uydurma. Bilgi yoksa fiyat yazma.
- İşletmenin adını, telefonunu ve adresini işletme verisinden kullan; veri yoksa o kısmı yazma.
- İstenen kanala göre biçimlendir:
  • WhatsApp mesajı: 2-4 kısa cümle, en fazla 3 emoji, sonunda işletme adı ve telefon.
  • Instagram gönderisi: dikkat çekici ilk satır, kısa açıklama, sonunda 4-6 hashtag.
  • Dükkân afişi: büyük başlık, 1-2 satır alt başlık, varsa kısa koşul satırı.
- Birden fazla kanal istenirse her birini ayrı başlıkla ver.
- En sona tek satırlık bir not ekle: toplu mesaj göndermeden önce müşterilerin ileti izni (İYS) olması gerektiğini hatırlat.
- Kullanıcı fikir isterse işletme verisine (çok satan, azalan ya da satılmayan ürünler) dayanarak 3 kısa kampanya fikri öner.`;

const STANDART_NOTU = `

Bu işletme Standart pakette. Kampanya, reklam metni ya da afiş yazma isteklerinde bunun Pro paketteki Kampanyalar bölümünde olduğunu kısaca söyle; metni yazma.`;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return yanit({ hata: "Geçersiz istek" }, 405);

  const SUPA_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const SUPA_KEY = Deno.env.get("SUPABASE_ANON_KEY") || req.headers.get("apikey") || "";
  const AI_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
  const MODEL = Deno.env.get("AI_MODEL") || "claude-haiku-5-5";
  const AI_URL = (Deno.env.get("ANTHROPIC_API_URL") || "https://api.anthropic.com").replace(/\/$/, "");

  const yetki = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(yetki)) return yanit({ hata: "Önce giriş yapın" }, 401);

  // deno-lint-ignore no-explicit-any
  let govde: any;
  try {
    govde = await req.json();
  } catch {
    return yanit({ hata: "Geçersiz istek" }, 400);
  }
  const tur = govde?.tur === "kampanya" ? "kampanya" : "soru";
  const soru = String(govde?.soru ?? "").trim().slice(0, 3000);
  if (!soru) return yanit({ hata: "Bir soru yazın" }, 400);

  // Veritabanına giriş yapan kişinin kendi yetkisiyle sorulur: yalnızca kendi işletmesini görür
  // deno-lint-ignore no-explicit-any
  async function rpc(ad: string, args: Record<string, unknown> = {}): Promise<any> {
    const r = await fetch(`${SUPA_URL}/rest/v1/rpc/${ad}`, {
      method: "POST",
      headers: { apikey: SUPA_KEY, Authorization: yetki, "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
    const metin = await r.text();
    // deno-lint-ignore no-explicit-any
    let j: any = null;
    try {
      j = metin ? JSON.parse(metin) : null;
    } catch {
      j = null;
    }
    if (!r.ok) {
      const e = new Error(r.status === 401 ? "Oturumun sona ermiş, yeniden giriş yap" : (j?.message || "İşlem yapılamadı"));
      // deno-lint-ignore no-explicit-any
      (e as any).durum = r.status;
      throw e;
    }
    return j;
  }

  if (!AI_KEY) {
    return yanit({ hata: "Asistan henüz bağlanmadı. Kurucunun Supabase'e ANTHROPIC_API_KEY anahtarını eklemesi gerekiyor." }, 503);
  }

  // deno-lint-ignore no-explicit-any
  let hak: any, veri: any;
  try {
    hak = await rpc("ai_hak", { p_tur: tur });
  } catch (e) {
    // deno-lint-ignore no-explicit-any
    const h = e as any;
    return yanit({ hata: h.message }, h.durum === 401 ? 401 : 403);
  }
  try {
    veri = await rpc("ai_veri");
  } catch (e) {
    return yanit({ hata: (e as Error).message }, 500);
  }

  // Önceki konuşma (en fazla son 6 mesaj); roller sırayla user/assistant olmalı
  const mesajlar: { role: "user" | "assistant"; content: string }[] = [];
  const gecmis = Array.isArray(govde?.gecmis) ? govde.gecmis.slice(-6) : [];
  for (const m of gecmis) {
    const rol = m?.rol === "asistan" ? "assistant" : m?.rol === "kullanici" ? "user" : null;
    const icerik = String(m?.metin ?? "").trim().slice(0, 3000);
    if (!rol || !icerik) continue;
    if (!mesajlar.length && rol !== "user") continue;
    const son = mesajlar[mesajlar.length - 1];
    if (son && son.role === rol) son.content += "\n\n" + icerik;
    else mesajlar.push({ role: rol, content: icerik });
  }
  if (mesajlar.length && mesajlar[mesajlar.length - 1].role === "user") mesajlar.pop();
  mesajlar.push({ role: "user", content: soru });

  const sistem = (tur === "kampanya" ? SISTEM_KAMPANYA : SISTEM_SORU) +
    (tur === "soru" && !hak?.pro ? STANDART_NOTU : "") +
    "\n\nİşletme verisi (JSON):\n" + JSON.stringify(veri);

  const iptal = new AbortController();
  const zaman = setTimeout(() => iptal.abort(), 55000);
  let r: Response;
  try {
    r = await fetch(`${AI_URL}/v1/messages`, {
      method: "POST",
      signal: iptal.signal,
      headers: { "x-api-key": AI_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: tur === "kampanya" ? 1500 : 1000, system: sistem, messages: mesajlar }),
    });
  } catch {
    clearTimeout(zaman);
    return yanit({ hata: "Asistana ulaşılamadı. Biraz sonra tekrar dene." }, 502);
  }
  clearTimeout(zaman);

  if (!r.ok) {
    const metin = await r.text();
    console.error("Claude API hatası", r.status, metin.slice(0, 500));
    const hata = r.status === 401 || r.status === 403
      ? "Asistan anahtarı geçersiz. Kurucunun ANTHROPIC_API_KEY anahtarını kontrol etmesi gerekiyor."
      : r.status === 429 || r.status === 529
      ? "Asistan şu an çok yoğun. Bir dakika sonra tekrar dene."
      : /credit|balance/i.test(metin)
      ? "Asistan kredisi bitti. Kurucunun Claude hesabına kredi yüklemesi gerekiyor."
      : "Asistan şu an cevap veremiyor. Biraz sonra tekrar dene.";
    return yanit({ hata }, 502);
  }

  // deno-lint-ignore no-explicit-any
  const j: any = await r.json();
  // deno-lint-ignore no-explicit-any
  const cevap = (j?.content ?? []).filter((b: any) => b?.type === "text").map((b: any) => b.text).join("\n").trim();
  return yanit({ cevap: cevap || "Bir cevap oluşturamadım, soruyu biraz farklı yazar mısın?", kalan: hak?.kalan ?? null });
});

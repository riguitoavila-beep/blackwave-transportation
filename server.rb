require 'webrick'
require 'net/http'
require 'json'
require 'securerandom'
require 'date'

# ── APP ROOT — absolute path regardless of CWD ────────────
APP_ROOT = File.expand_path(__dir__)

# ── CONFIG ────────────────────────────────────────────────
SQUARE_ACCESS_TOKEN = ENV['SQUARE_TOKEN']       || 'EAAAl9BK3APGEkUmkde-mPPH1NQBnQFslgkIl85n7b-MdAc1JXqh6_7HUQlsXVel'
SQUARE_APP_ID       = ENV['SQUARE_APP_ID']      || 'sq0idp-uF_6ZCJ60TpW-fsgYb1EiQ'
SQUARE_LOCATION_ID  = ENV['SQUARE_LOCATION_ID'] || 'LYXVDKX4CDHCD'
SQUARE_API_HOST     = 'connect.squareup.com'
ADMIN_PASSWORD      = ENV['ADMIN_PASS'] || 'blackwave2026'
ICAL_TOKEN          = ENV['ICAL_TOKEN']  || 'BlackWave2026'
BUFFER_MINS         = 20

# ── BOOKINGS FILE — validate path stays within app dir ────
_bookings_raw = ENV['BOOKINGS_FILE'] || File.join(APP_ROOT, 'bookings.json')
BOOKINGS_FILE = if File.expand_path(_bookings_raw).start_with?(APP_ROOT)
  _bookings_raw
else
  warn "[SECURITY] BOOKINGS_FILE path rejected — using default"
  File.join(APP_ROOT, 'bookings.json')
end

# ── ALLOWED ORIGINS for CORS ──────────────────────────────
# Set CORS_ORIGIN env var in production (e.g. https://blackwavemiami.com)
# Defaults to '*' only for local dev
CORS_ORIGIN = ENV['CORS_ORIGIN'] || '*'

# ── RATE LIMIT: max bookings per IP per 10 minutes ────────
RATE_LIMIT_MAX    = 5
RATE_LIMIT_WINDOW = 600  # seconds
$rate_limit       = {}   # ip => [timestamps]
$rl_mu            = Mutex.new

def rate_limited?(ip)
  $rl_mu.synchronize do
    now  = Time.now.to_i
    hits = ($rate_limit[ip] || []).select { |t| now - t < RATE_LIMIT_WINDOW }
    $rate_limit[ip] = hits
    return true if hits.size >= RATE_LIMIT_MAX
    $rate_limit[ip] << now
    false
  end
end
# ──────────────────────────────────────────────────────────

$sessions = {}   # token => expires_at
$mu       = Mutex.new

# ── Storage helpers ────────────────────────────────────────
def load_bookings
  $mu.synchronize do
    return [] unless File.exist?(BOOKINGS_FILE)
    JSON.parse(File.read(BOOKINGS_FILE)) rescue []
  end
end

def save_bookings!(list)
  $mu.synchronize { File.write(BOOKINGS_FILE, JSON.generate(list)) }
end

# ── HTTP helpers ───────────────────────────────────────────
def cors(res)
  res['Access-Control-Allow-Origin']  = CORS_ORIGIN
  res['Access-Control-Allow-Methods'] = 'GET, POST, PATCH, DELETE, OPTIONS'
  res['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
  res['X-Content-Type-Options']       = 'nosniff'
  res['X-Frame-Options']              = 'DENY'
  res['Referrer-Policy']              = 'strict-origin-when-cross-origin'
end


def ok(res, body)
  res.status = 200
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate(body)
end

def err(res, status, msg)
  res.status = status
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate({ error: msg })
end

# ── Session auth ───────────────────────────────────────────
def valid_session?(req)
  token = req['Authorization']&.sub('Bearer ', '')&.strip
  return false unless token && !token.empty?
  exp = $sessions[token]
  exp && exp > Time.now
end

# ── Availability / buffer helpers ──────────────────────────
def t2m(str)  # "HH:MM" → minutes from midnight
  return nil unless str&.match?(/\d{1,2}:\d{2}/)
  h, m = str.split(':').map(&:to_i)
  h * 60 + m
end

def m2t(mins)  # minutes → "HH:MM"
  format('%02d:%02d', (mins / 60) % 24, mins % 60)
end

def blocked_ranges(date_str)
  load_bookings.flat_map do |b|
    next [] if %w[cancelled completed].include?(b['status'])
    ranges = []
    # Outbound leg (or single leg)
    if b['date'] == date_str
      sm = t2m(b['time'])
      if sm
        dur = [b['estimatedMins'].to_i, 20].max
        ranges << { from: sm, until: sm + dur + BUFFER_MINS }
      end
    end
    # Return leg (round trip)
    if b['tripType'] == 'roundtrip' && b['returnDate'] == date_str
      sm = t2m(b['returnTime'])
      if sm
        dur = [b['estimatedMins'].to_i, 20].max
        ranges << { from: sm, until: sm + dur + BUFFER_MINS }
      end
    end
    ranges
  end
end

# ── SERVLET: Square Checkout ───────────────────────────────
class CheckoutServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_POST(req, res)
    cors(res)
    res['Content-Type'] = 'application/json'

    # Guard: token no configurado
    if SQUARE_ACCESS_TOKEN == 'PASTE_YOUR_ACCESS_TOKEN_HERE' || SQUARE_ACCESS_TOKEN.to_s.strip.empty?
      res.status = 503
      res.body = JSON.generate({ error: 'Square token not configured. Start server with SQUARE_TOKEN=... ruby server.rb' })
      return
    end

    # Guard: body vacío o malformado
    body = begin
      JSON.parse(req.body.to_s)
    rescue JSON::ParserError
      res.status = 400; res.body = JSON.generate({ error: 'Invalid JSON body' }); return
    end

    amount_cents = body['amount_cents'].to_i
    booking_id   = body['booking_id'].to_s.strip
    note         = body['note'].to_s[0, 500]

    if amount_cents <= 0
      res.status = 400; res.body = JSON.generate({ error: 'Invalid amount' }); return
    end
    if booking_id.empty?
      res.status = 400; res.body = JSON.generate({ error: 'Missing booking_id' }); return
    end

    payload = {
      idempotency_key: SecureRandom.uuid,
      quick_pay: {
        name:        'BlackWave Transportation Deposit',
        price_money: { amount: amount_cents, currency: 'USD' },
        location_id: SQUARE_LOCATION_ID
      },
      checkout_options: {
        ask_for_shipping_address: false,
        accepted_payment_methods: { apple_pay: true, google_pay: true, cash_app_pay: false }
      },
      pre_populated_data: { buyer_note: note },
      payment_note: "Booking #{booking_id}"
    }

    http            = Net::HTTP.new(SQUARE_API_HOST, 443)
    http.use_ssl    = true
    http.open_timeout = 10
    http.read_timeout = 15
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER

    request = Net::HTTP::Post.new('/v2/online-checkout/payment-links')
    request['Authorization']  = "Bearer #{SQUARE_ACCESS_TOKEN}"
    request['Content-Type']   = 'application/json'
    request['Square-Version'] = '2025-01-23'
    request.body = JSON.generate(payload)

    response = http.request(request)
    sq_body  = JSON.parse(response.body) rescue {}

    puts "[Square] #{response.code} — booking #{booking_id} — #{amount_cents}¢"

    if response.code.to_i == 200 && sq_body['payment_link']&.[]('url')
      ok(res, { url: sq_body['payment_link']['url'] })
    else
      detail = sq_body.dig('errors', 0, 'detail') ||
               sq_body.dig('errors', 0, 'code')   ||
               "Square API error (HTTP #{response.code})"
      puts "[Square ERROR] #{detail}"
      res.status = 502
      res.body   = JSON.generate({ error: detail })
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    res.status = 504; res.body = JSON.generate({ error: 'Square API timeout — try again' })
  rescue => e
    puts "[CheckoutServlet ERROR] #{e.class}: #{e.message}"
    res.status = 500; res.body = JSON.generate({ error: e.message })
  end

  def do_OPTIONS(req, res); cors(res); res.status = 204; res.body = ''; end
end

# ── SERVLET: API Router ────────────────────────────────────
class APIServlet < WEBrick::HTTPServlet::AbstractServlet
  def service(req, res)
    cors(res)
    return (res.status = 204; res.body = '') if req.request_method == 'OPTIONS'

    m    = req.request_method
    path = req.path

    case [m, path]
    when ['GET',  '/api/health']         then ok(res, { status: 'ok', time: Time.now.iso8601 })
    when ['POST', '/api/admin/login']    then admin_login(req, res)
    when ['GET',  '/api/bookings']       then list_bookings(req, res)
    when ['POST', '/api/bookings']       then create_booking(req, res)
    when ['GET',  '/api/availability']  then availability(req, res)
    when ['GET',  '/api/admin/stats']   then stats(req, res)
    when ['GET',  '/api/admin/revenue'] then revenue(req, res)
    else
      if m == 'PATCH'  && path =~ %r{^/api/bookings/(.+)$} then update_booking(req, res, $1)
      elsif m == 'DELETE' && path =~ %r{^/api/bookings/(.+)$} then cancel_booking(req, res, $1)
      else err(res, 404, 'Not found')
      end
    end
  rescue => e
    err(res, 500, e.message)
  end

  private

  def body_json(req)
    JSON.parse(req.body || '{}') rescue {}
  end

  def admin_login(req, res)
    b = body_json(req)
    if b['password'] == ADMIN_PASSWORD
      token = SecureRandom.hex(32)
      $sessions[token] = Time.now + 28_800  # 8 hours
      ok(res, { token: token })
    else
      err(res, 401, 'Invalid password')
    end
  end

  def list_bookings(req, res)
    return err(res, 401, 'Unauthorized') unless valid_session?(req)
    list = load_bookings.sort_by { |b| [b['date'] || '', b['time'] || ''] }.reverse
    ok(res, list)
  end

  def create_booking(req, res)
    # Rate limiting: max 5 bookings per IP per 10 minutes
    client_ip = req['X-Forwarded-For']&.split(',')&.first&.strip || req.peeraddr[3]
    if rate_limited?(client_ip)
      res.status = 429
      res['Content-Type'] = 'application/json'
      res['Retry-After']  = '600'
      res.body = JSON.generate({ error: 'Too many requests — please try again later.' })
      return
    end

    b = body_json(req)
    return err(res, 400, 'Empty body') if b.empty?

    # Sanitize fields — strip tags, limit lengths
    safe = {
      'id'            => b['id'].to_s[0, 40].gsub(/[^A-Za-z0-9\-]/, ''),
      'tripType'      => b['tripType'].to_s[0, 20].gsub(/[^a-z]/, ''),
      'name'          => b['name'].to_s[0, 100].strip,
      'phone'         => b['phone'].to_s[0, 30].gsub(/[^0-9\+\-\(\) ]/, ''),
      'email'         => b['email'].to_s[0, 200].downcase.strip,
      'passengers'    => [[b['passengers'].to_i, 1].max, 20].min.to_s,
      'date'          => b['date'].to_s[0, 10].gsub(/[^0-9\-]/, ''),
      'time'          => b['time'].to_s[0, 5].gsub(/[^0-9:]/, ''),
      'special'       => b['special'].to_s[0, 500].strip,
      'total'         => b['total'].to_f.round(2),
      'deposit'       => b['deposit'].to_f.round(2),
      'estimatedMins' => b['estimatedMins'].to_i,
      'pickupAddress' => b['pickupAddress'].to_s[0, 300].strip,
      'dropoffAddress'=> b['dropoffAddress'].to_s[0, 300].strip,
      'returnDate'    => b['returnDate'].to_s[0, 10].gsub(/[^0-9\-]/, ''),
      'returnTime'    => b['returnTime'].to_s[0, 5].gsub(/[^0-9:]/, ''),
    }

    list    = load_bookings
    booking = safe.merge('status' => 'pending', 'createdAt' => Time.now.iso8601)
    list << booking
    save_bookings!(list)
    puts "[BookingCreated] #{booking['id']} — #{booking['name']} — #{booking['date']} #{booking['time']}"
    Thread.new { notify_admin_wa(booking) rescue nil }
    ok(res, { ok: true, booking: booking })
  end

  def update_booking(req, res, id)
    return err(res, 401, 'Unauthorized') unless valid_session?(req)
    b    = body_json(req)
    list = load_bookings
    idx  = list.index { |x| x['id'] == id }
    return err(res, 404, 'Not found') unless idx
    list[idx] = list[idx].merge(b).merge('updatedAt' => Time.now.iso8601)
    save_bookings!(list)
    ok(res, { ok: true, booking: list[idx] })
  end

  def cancel_booking(req, res, id)
    return err(res, 401, 'Unauthorized') unless valid_session?(req)
    list = load_bookings
    idx  = list.index { |x| x['id'] == id }
    return err(res, 404, 'Not found') unless idx
    list[idx]['status']      = 'cancelled'
    list[idx]['cancelledAt'] = Time.now.iso8601
    save_bookings!(list)
    ok(res, { ok: true })
  end

  def availability(req, res)
    date   = req.query['date'] || ''
    ranges = blocked_ranges(date).map { |r| { from: m2t(r[:from]), until: m2t(r[:until]) } }
    ok(res, { date: date, blocked: ranges })
  end

  def stats(req, res)
    return err(res, 401, 'Unauthorized') unless valid_session?(req)
    list   = load_bookings
    today  = Date.today.to_s
    active = list.reject { |b| b['status'] == 'cancelled' }
    ok(res, {
      total:           list.size,
      pending:         list.count { |b| b['status'] == 'pending' },
      confirmed:       list.count { |b| b['status'] == 'confirmed' },
      completed:       list.count { |b| b['status'] == 'completed' },
      cancelled:       list.count { |b| b['status'] == 'cancelled' },
      today:           list.count { |b| b['date'] == today && b['status'] != 'cancelled' },
      revenue_total:   active.sum { |b| b['total'].to_f }.round(2),
      revenue_deposit: active.sum { |b| b['deposit'].to_f }.round(2)
    })
  end

  def revenue(req, res)
    return err(res, 401, 'Unauthorized') unless valid_session?(req)
    active = load_bookings.reject { |b| b['status'] == 'cancelled' }
    monthly = Hash.new { |h, k| h[k] = { bookings: 0, revenue: 0.0, deposit: 0.0 } }
    active.each do |b|
      next unless b['date']&.length.to_i >= 7
      month = b['date'][0, 7]
      monthly[month][:bookings] += 1
      monthly[month][:revenue]  += b['total'].to_f
      monthly[month][:deposit]  += b['deposit'].to_f
    end
    result = monthly.sort.last(6).map do |month, d|
      { month: month, bookings: d[:bookings], revenue: d[:revenue].round(2), deposit: d[:deposit].round(2) }
    end
    ok(res, result)
  end

  def notify_admin_wa(b)
    trip_labels = {
      'p2p' => 'Point-to-Point', 'hourly' => 'Hourly',
      'airport' => 'Airport Transfer', 'seaport' => 'Seaport Transfer',
      'fisher' => 'Fisher Island', 'roundtrip' => 'Round Trip'
    }
    trip  = trip_labels[b['tripType']] || b['tripType'].to_s
    total = '$%.2f' % b['total'].to_f
    dep   = '$%.2f' % b['deposit'].to_f
    msg   = URI.encode_www_form_component(
      "🖤 NEW BLACKWAVE BOOKING\n" \
      "👤 #{b['name']}\n📞 #{b['phone']}\n📧 #{b['email']}\n" \
      "📅 #{b['date']} at #{b['time']}\n" \
      "🚗 #{trip}\n👥 #{b['passengers']} passenger(s)\n" \
      "💰 Total: #{total} | Deposit: #{dep}\n" \
      "📌 ID: #{b['id']}"
    )
    url = URI("https://api.callmebot.com/whatsapp.php?phone=17867542078&text=#{msg}&apikey=admin")
    # Solo log — no envía request real (CallMeBot requiere setup previo)
    # Para activar: reemplaza la línea de abajo con Net::HTTP.get(url)
    puts "[AdminNotify] WA message prepared for booking #{b['id']}"
  end
end

# ── SERVLET: iCal Feed ────────────────────────────────────
class ICalServlet < WEBrick::HTTPServlet::AbstractServlet
  TRIP_LABELS = {
    'p2p'       => 'Point-to-Point',
    'hourly'    => 'Hourly Service',
    'airport'   => 'Airport Transfer',
    'seaport'   => 'Seaport Transfer',
    'fisher'    => 'Fisher Island Transfer',
    'roundtrip' => 'Round Trip'
  }.freeze

  def do_GET(req, res)
    # ── Token check ──
    token = req.query['token'].to_s.strip
    if token != ICAL_TOKEN
      res.status = 401
      res['Content-Type'] = 'text/plain'
      res.body = 'Unauthorized'
      return
    end

    bookings = load_bookings.reject { |b| b['status'] == 'cancelled' }
    now_stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')

    lines = []
    lines << 'BEGIN:VCALENDAR'
    lines << 'VERSION:2.0'
    lines << 'PRODID:-//BlackWave Transportation//Bookings//EN'
    lines << 'CALSCALE:GREGORIAN'
    lines << 'METHOD:PUBLISH'
    lines << 'X-WR-CALNAME:BlackWave Bookings'
    lines << 'X-WR-TIMEZONE:America/New_York'
    lines << 'REFRESH-INTERVAL;VALUE=DURATION:PT15M'
    lines << 'X-PUBLISHED-TTL:PT15M'

    bookings.each do |b|
      date_str = b['date'].to_s   # "YYYY-MM-DD"
      time_str = b['time'].to_s   # "HH:MM"
      next if date_str.empty? || time_str.empty?

      # Build start datetime
      dt_start = begin
        DateTime.parse("#{date_str}T#{time_str}:00-04:00")
      rescue
        next
      end

      dur_mins = [b['estimatedMins'].to_i, 30].max
      dt_end   = dt_start + Rational(dur_mins, 1440)

      start_fmt = dt_start.strftime('%Y%m%dT%H%M%S')
      end_fmt   = dt_end.strftime('%Y%m%dT%H%M%S')
      uid       = "#{b['id']}@blackwave.local"

      trip    = TRIP_LABELS[b['tripType']] || b['tripType'].to_s.capitalize
      name    = b['name'].to_s
      phone   = b['phone'].to_s
      email   = b['email'].to_s
      pax     = b['passengers'].to_s
      total   = '$%.2f' % b['total'].to_f
      deposit = '$%.2f' % b['deposit'].to_f
      status  = b['status'].to_s.upcase
      pickup  = b['pickupAddress'].to_s
      dropoff = b['dropoffAddress'].to_s

      summary = "🖤 #{name} — #{trip}"
      desc    = "ID: #{b['id']}\\n" \
                "Client: #{name} | #{phone} | #{email}\\n" \
                "Passengers: #{pax}\\n" \
                "Service: #{trip}\\n" \
                "Total: #{total} | Deposit paid: #{deposit}\\n" \
                "Status: #{status}" \
                + (pickup.empty?  ? '' : "\\nPickup: #{pickup}") \
                + (dropoff.empty? ? '' : "\\nDropoff: #{dropoff}")

      location = pickup.empty? ? 'Miami, FL' : pickup

      lines << 'BEGIN:VEVENT'
      lines << "UID:#{uid}"
      lines << "DTSTAMP:#{now_stamp}"
      lines << "DTSTART;TZID=America/New_York:#{start_fmt}"
      lines << "DTEND;TZID=America/New_York:#{end_fmt}"
      lines << "SUMMARY:#{ical_escape(summary)}"
      lines << "DESCRIPTION:#{ical_escape(desc)}"
      lines << "LOCATION:#{ical_escape(location)}"
      lines << "STATUS:#{b['status'] == 'confirmed' ? 'CONFIRMED' : 'TENTATIVE'}"
      lines << 'END:VEVENT'

      # Round-trip return leg
      if b['tripType'] == 'roundtrip' && !b['returnDate'].to_s.empty? && !b['returnTime'].to_s.empty?
        begin
          dt_r   = DateTime.parse("#{b['returnDate']}T#{b['returnTime']}:00-04:00")
          dt_re  = dt_r + Rational(dur_mins, 1440)
          lines << 'BEGIN:VEVENT'
          lines << "UID:#{b['id']}-return@blackwave.local"
          lines << "DTSTAMP:#{now_stamp}"
          lines << "DTSTART;TZID=America/New_York:#{dt_r.strftime('%Y%m%dT%H%M%S')}"
          lines << "DTEND;TZID=America/New_York:#{dt_re.strftime('%Y%m%dT%H%M%S')}"
          lines << "SUMMARY:#{ical_escape("🔄 #{name} — Return Trip")}"
          lines << "DESCRIPTION:#{ical_escape("Return leg for booking #{b['id']}\\nClient: #{name}")}"
          lines << "LOCATION:#{ical_escape(dropoff.empty? ? 'Miami, FL' : dropoff)}"
          lines << "STATUS:#{b['status'] == 'confirmed' ? 'CONFIRMED' : 'TENTATIVE'}"
          lines << 'END:VEVENT'
        rescue; end
      end
    end

    lines << 'END:VCALENDAR'

    # iCal spec: lines must be folded at 75 chars
    ical_body = lines.map { |l| fold_line(l) }.join("\r\n") + "\r\n"

    res.status = 200
    res['Content-Type']        = 'text/calendar; charset=utf-8'
    res['Content-Disposition'] = 'inline; filename="blackwave.ics"'
    res['Cache-Control']       = 'no-cache, no-store'
    res.body = ical_body
  rescue => e
    res.status = 500
    res['Content-Type'] = 'text/plain'
    res.body = "iCal error: #{e.message}"
  end

  private

  def ical_escape(str)
    str.to_s.gsub('\\', '\\\\').gsub("\n", '\\n').gsub(',', '\\,').gsub(';', '\\;')
  end

  # RFC 5545 line folding: max 75 octets, continuation with CRLF + SPACE
  def fold_line(line)
    return line if line.bytesize <= 75
    out   = ''
    bytes = 0
    line.each_char do |c|
      cb = c.bytesize
      if bytes + cb > 75
        out   += "\r\n "
        bytes  = 1
      end
      out   += c
      bytes += cb
    end
    out
  end
end

# ── SERVLET: Static file server (explicit — no WEBrick FileHandler) ──
class StaticServlet < WEBrick::HTTPServlet::AbstractServlet
  MIME = {
    '.html'        => 'text/html; charset=utf-8',
    '.css'         => 'text/css',
    '.js'          => 'application/javascript',
    '.json'        => 'application/json',
    '.png'         => 'image/png',
    '.jpg'         => 'image/jpeg',
    '.jpeg'        => 'image/jpeg',
    '.gif'         => 'image/gif',
    '.svg'         => 'image/svg+xml',
    '.ico'         => 'image/x-icon',
    '.webmanifest' => 'application/manifest+json',
    '.woff'        => 'font/woff',
    '.woff2'       => 'font/woff2',
    '.txt'         => 'text/plain',
  }.freeze

  CSP = "default-src 'self'; " \
        "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://maps.googleapis.com https://maps.gstatic.com https://cdn.emailjs.com; " \
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " \
        "font-src 'self' https://fonts.gstatic.com; " \
        "img-src 'self' data: https: blob:; " \
        "connect-src 'self' https://api.emailjs.com https://maps.googleapis.com; " \
        "frame-src https://squareup.com https://*.squareup.com; " \
        "object-src 'none'; base-uri 'self'".freeze

  def do_GET(req, res)
    # Normalise path
    raw = req.path.dup
    raw = '/index.html' if raw == '/' || raw.empty?
    raw = '/admin.html' if raw == '/admin'

    # Resolve to absolute path and prevent traversal
    full = File.expand_path(File.join(APP_ROOT, raw))
    unless full.start_with?(APP_ROOT + '/')
      res.status = 403; res['Content-Type'] = 'text/plain'; res.body = 'Forbidden'; return
    end

    unless File.file?(full)
      res.status = 404; res['Content-Type'] = 'text/html; charset=utf-8'
      res.body = '<html><body style="font-family:sans-serif;padding:40px"><h2>404 — Not Found</h2></body></html>'
      return
    end

    ext          = File.extname(full).downcase
    content_type = MIME[ext] || 'application/octet-stream'
    html         = content_type.include?('text/html')

    res.status         = 200
    res['Content-Type'] = content_type
    res['Cache-Control'] = html ? 'no-cache, must-revalidate' : 'public, max-age=86400'
    res.body           = File.binread(full)

    if html
      res['X-Content-Type-Options'] = 'nosniff'
      res['X-Frame-Options']        = 'SAMEORIGIN'
      res['Referrer-Policy']        = 'strict-origin-when-cross-origin'
      res['Permissions-Policy']     = 'geolocation=(), microphone=(), camera=()'
      res['Content-Security-Policy'] = CSP
    end
  end

  alias do_HEAD do_GET
end

# ── SERVER ─────────────────────────────────────────────────
port   = (ENV['PORT'] || 8080).to_i
$stdout.sync = true   # flush immediately — Railway streams logs line by line
server = WEBrick::HTTPServer.new(
  Port:        port,
  BindAddress: '0.0.0.0',
  Logger:      WEBrick::Log.new($stdout),
  AccessLog:   [[$stdout, WEBrick::AccessLog::COMBINED_LOG_FORMAT]]
)

server.mount('/api/checkout',              CheckoutServlet)
server.mount('/api/bookings/calendar.ics', ICalServlet)
server.mount('/api',                       APIServlet)
server.mount('/',                          StaticServlet)

trap('INT')  { server.shutdown }
trap('TERM') { server.shutdown }

puts "\n🖤  BlackWave server  →  http://0.0.0.0:#{port}"
puts "    Square token set :  #{!SQUARE_ACCESS_TOKEN.include?('PASTE')}"
puts "    Bookings file    :  #{BOOKINGS_FILE}\n\n"

server.start

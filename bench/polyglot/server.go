package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

type jsonMeta struct {
	Region string `json:"region"`
	Rev    int    `json:"rev"`
}

type jsonItem struct {
	ID     int      `json:"id"`
	Name   string   `json:"name"`
	Email  string   `json:"email"`
	Role   string   `json:"role"`
	Active bool     `json:"active"`
	Score  float64  `json:"score"`
	Tags   []string `json:"tags"`
	Meta   jsonMeta `json:"meta"`
}

type jsonPayload struct {
	Status string     `json:"status"`
	Count  int        `json:"count"`
	Items  []jsonItem `json:"items"`
}

type postItem struct {
	Score float64 `json:"score"`
}

type postRequest struct {
	Status string     `json:"status"`
	Items  []postItem `json:"items"`
}

type postResponse struct {
	Status   string `json:"status"`
	Count    int    `json:"count"`
	Checksum int64  `json:"checksum"`
}

type templateRow struct {
	ID    int
	Title string
	Owner string
	Note  string
	Score string
}

type templateData struct {
	Title string
	Rows  []templateRow
}

type cacheResponse struct {
	Key    string `json:"key"`
	Value  string `json:"value"`
	Shared bool   `json:"shared"`
}

type keydbResponse struct {
	Key   string `json:"key"`
	Value string `json:"value"`
	Count int64  `json:"count"`
	XS    bool   `json:"xs"`
}

type staticEntry struct {
	mtime        time.Time
	size         int64
	content      []byte
	etag         string
	lastModified string
}

// Persistent pooled RESP2 TCP client
type respConn struct {
	conn net.Conn
	r    *bufio.Reader
	w    *bufio.Writer
}

type respPool struct {
	addr string
	ch   chan *respConn
}

func newRespPool(addr string, maxIdle int) *respPool {
	return &respPool{
		addr: addr,
		ch:   make(chan *respConn, maxIdle),
	}
}

func (p *respPool) get() (*respConn, error) {
	select {
	case c := <-p.ch:
		return c, nil
	default:
	}
	conn, err := net.DialTimeout("tcp", p.addr, 2*time.Second)
	if err != nil {
		return nil, err
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	return &respConn{
		conn: conn,
		r:    bufio.NewReaderSize(conn, 4096),
		w:    bufio.NewWriterSize(conn, 4096),
	}, nil
}

func (p *respPool) put(c *respConn) {
	select {
	case p.ch <- c:
	default:
		_ = c.conn.Close()
	}
}

func (c *respConn) writeCmd(args ...string) error {
	if _, err := fmt.Fprintf(c.w, "*%d\r\n", len(args)); err != nil {
		return err
	}
	for _, a := range args {
		if _, err := fmt.Fprintf(c.w, "$%d\r\n%s\r\n", len(a), a); err != nil {
			return err
		}
	}
	return c.w.Flush()
}

func (c *respConn) readLine() (string, error) {
	line, err := c.r.ReadString('\n')
	if err != nil {
		return "", err
	}
	n := len(line)
	if n >= 2 && line[n-2] == '\r' {
		return line[:n-2], nil
	}
	return line[:n-1], nil
}

func (c *respConn) readInt() (int64, error) {
	line, err := c.readLine()
	if err != nil {
		return 0, err
	}
	if len(line) == 0 || line[0] != ':' {
		return 0, fmt.Errorf("unexpected RESP2 int reply: %q", line)
	}
	return strconv.ParseInt(line[1:], 10, 64)
}

func (c *respConn) readBulk() (string, bool, error) {
	line, err := c.readLine()
	if err != nil {
		return "", false, err
	}
	if len(line) == 0 || line[0] != '$' {
		return "", false, fmt.Errorf("unexpected RESP2 bulk reply: %q", line)
	}
	n, err := strconv.Atoi(line[1:])
	if err != nil {
		return "", false, err
	}
	if n < 0 {
		return "", false, nil
	}
	buf := make([]byte, n+2)
	if _, err := io.ReadFull(c.r, buf); err != nil {
		return "", false, err
	}
	return string(buf[:n]), true, nil
}

func (c *respConn) readSimple() (string, error) {
	line, err := c.readLine()
	if err != nil {
		return "", err
	}
	if len(line) == 0 || line[0] != '+' {
		return "", fmt.Errorf("unexpected RESP2 simple reply: %q", line)
	}
	return line[1:], nil
}

func (p *respPool) incrAndGet(key string) (int64, string, error) {
	c, err := p.get()
	if err != nil {
		return 0, "", err
	}
	cntKey := "bench:cnt:" + key
	valKey := "bench:val:" + key

	if err := c.writeCmd("INCR", cntKey); err != nil {
		_ = c.conn.Close()
		return 0, "", err
	}
	count, err := c.readInt()
	if err != nil {
		_ = c.conn.Close()
		return 0, "", err
	}

	if err := c.writeCmd("GET", valKey); err != nil {
		_ = c.conn.Close()
		return 0, "", err
	}
	val, ok, err := c.readBulk()
	if err != nil {
		_ = c.conn.Close()
		return 0, "", err
	}
	if !ok {
		val = "keydb:" + key + ":v1"
		if err := c.writeCmd("SET", valKey, val); err != nil {
			_ = c.conn.Close()
			return 0, "", err
		}
		if _, err := c.readSimple(); err != nil {
			_ = c.conn.Close()
			return 0, "", err
		}
	}

	p.put(c)
	return count, val, nil
}

func buildJSONPayload() jsonPayload {
	items := make([]jsonItem, 0, 50)
	for i := 1; i <= 50; i++ {
		role := "member"
		if i%5 == 0 {
			role = "admin"
		}
		region := "eu-west"
		if i%2 != 0 {
			region = "us-east"
		}
		items = append(items, jsonItem{
			ID:     i,
			Name:   fmt.Sprintf("Benchmark User %d", i),
			Email:  fmt.Sprintf("user%d@example.com", i),
			Role:   role,
			Active: i%3 != 0,
			Score:  10.5 + float64(i)*1.25,
			Tags:   []string{"perf", "mojo", fmt.Sprintf("tier-%d", i%4)},
			Meta:   jsonMeta{Region: region, Rev: i},
		})
	}
	return jsonPayload{Status: "ok", Count: len(items), Items: items}
}

func buildTemplateData() templateData {
	rows := make([]templateRow, 0, 25)
	for i := 1; i <= 25; i++ {
		rows = append(rows, templateRow{
			ID:    i,
			Title: fmt.Sprintf(`Item #%d <script>alert("xss&%d")</script> & 'quotes'`, i, i),
			Owner: fmt.Sprintf(`User <u%d@example.com> & "Team %d"`, i, i),
			Note:  `Value > 0 && Value < 100 ("ok" / 'checked')`,
			Score: fmt.Sprintf("%.2f", 50.0+float64(i)*1.75),
		})
	}
	return templateData{
		Title: `Benchmark <Report> & "Stats"`,
		Rows:  rows,
	}
}

const tableTemplateSrc = `<!DOCTYPE html>
<html>
<head><title>{{.Title}}</title></head>
<body>
<h1>{{.Title}}</h1>
<table>
<thead><tr><th>ID</th><th>Title</th><th>Owner</th><th>Note</th><th>Score</th></tr></thead>
<tbody>
{{range .Rows}}<tr><td>{{.ID}}</td><td>{{.Title}}</td><td>{{.Owner}}</td><td>{{.Note}}</td><td>{{.Score}}</td></tr>
{{end}}</tbody>
</table>
</body>
</html>
`

func ensureStaticAsset(publicDir string) error {
	assetPath := filepath.Join(publicDir, "static", "payload.txt")
	st, err := os.Stat(assetPath)
	if err == nil && st.Mode().IsRegular() && st.Size() == 16384 {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(assetPath), 0o755); err != nil {
		return err
	}
	line := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n"
	return os.WriteFile(assetPath, []byte(strings.Repeat(line, 256)), 0o644)
}

func main() {
	portFlag := flag.Int("port", 3000, "TCP listen port")
	workersFlag := flag.Int("workers", 8, "GOMAXPROCS worker count")
	keydbPortFlag := flag.Int("keydb-port", 0, "KeyDB TCP port")
	publicDirFlag := flag.String("public-dir", "", "Static public directory")
	flag.Parse()

	port := *portFlag
	if v := os.Getenv("PORT"); v != "" && port == 3000 {
		if p, err := strconv.Atoi(v); err == nil {
			port = p
		}
	}
	workers := *workersFlag
	if workers > 0 {
		runtime.GOMAXPROCS(workers)
	}
	keydbPort := *keydbPortFlag
	if keydbPort == 0 {
		if v := os.Getenv("MOJO_KEYDB_PORT"); v != "" {
			if p, err := strconv.Atoi(v); err == nil {
				keydbPort = p
			}
		}
	}
	publicDir := *publicDirFlag
	if publicDir == "" {
		if v := os.Getenv("PUBLIC_DIR"); v != "" {
			publicDir = v
		} else if _, err := os.Stat(filepath.Join("bench", "polyglot", "server.go")); err == nil {
			if abs, err := filepath.Abs(filepath.Join("bench", "public")); err == nil {
				publicDir = abs
			}
		}
		if publicDir == "" {
			exe, _ := os.Executable()
			publicDir = filepath.Clean(filepath.Join(filepath.Dir(exe), "..", "public"))
		}
	}
	if err := ensureStaticAsset(publicDir); err != nil {
		fmt.Fprintf(os.Stderr, "ensureStaticAsset: %v\n", err)
		os.Exit(1)
	}

	payload := buildJSONPayload()
	tmplData := buildTemplateData()
	tmpl := template.Must(template.New("table").Parse(tableTemplateSrc))
	bufPool := sync.Pool{New: func() any { return new(bytes.Buffer) }}

	var sharedCache sync.Map

	var staticMu sync.RWMutex
	staticCache := make(map[string]*staticEntry)
	const staticCacheMaxSize = 65536

	var kdb *respPool
	if keydbPort > 0 {
		kdb = newRespPool(fmt.Sprintf("127.0.0.1:%d", keydbPort), 64)
	}

	plaintextBytes := []byte("Hello, World!")

	mux := http.NewServeMux()

	// 1. GET /plaintext
	mux.HandleFunc("/plaintext", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/plain;charset=UTF-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(plaintextBytes)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(plaintextBytes)
	})

	// 2 & 3. GET /json and POST /json
	mux.HandleFunc("/json", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			b, err := json.Marshal(payload)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json;charset=UTF-8")
			w.Header().Set("Content-Length", strconv.Itoa(len(b)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(b)
		case http.MethodPost:
			body, err := io.ReadAll(r.Body)
			if err != nil {
				http.Error(w, `{"error":"read error"}`, http.StatusBadRequest)
				return
			}
			var req postRequest
			if err := json.Unmarshal(body, &req); err != nil {
				w.Header().Set("Content-Type", "application/json;charset=UTF-8")
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":"invalid json"}`))
				return
			}
			var sum float64
			for _, it := range req.Items {
				sum += it.Score
			}
			resp := postResponse{
				Status:   "ok",
				Count:    len(req.Items),
				Checksum: int64(sum*100 + 0.5),
			}
			b, err := json.Marshal(resp)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json;charset=UTF-8")
			w.Header().Set("Content-Length", strconv.Itoa(len(b)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(b)
		default:
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		}
	})

	// 4. GET /template
	mux.HandleFunc("/template", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		buf := bufPool.Get().(*bytes.Buffer)
		buf.Reset()
		defer bufPool.Put(buf)

		if err := tmpl.Execute(buf, tmplData); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		b := buf.Bytes()
		w.Header().Set("Content-Type", "text/html;charset=UTF-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(b)
	})

	// 5. GET /static/*
	mux.HandleFunc("/static/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		rel := strings.TrimPrefix(r.URL.Path, "/")
		if strings.Contains(rel, "..") || strings.Contains(rel, `\`) {
			http.NotFound(w, r)
			return
		}
		fullPath := filepath.Join(publicDir, rel)
		st, err := os.Stat(fullPath)
		if err != nil || !st.Mode().IsRegular() {
			http.NotFound(w, r)
			return
		}
		staticMu.RLock()
		entry, ok := staticCache[fullPath]
		staticMu.RUnlock()

		if !ok || !entry.mtime.Equal(st.ModTime()) || entry.size != st.Size() {
			content, err := os.ReadFile(fullPath)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			entry = &staticEntry{
				mtime:        st.ModTime(),
				size:         st.Size(),
				content:      content,
				etag:         fmt.Sprintf(`"%x-%x"`, st.Size(), st.ModTime().UnixNano()),
				lastModified: st.ModTime().UTC().Format(http.TimeFormat),
			}
			if st.Size() <= staticCacheMaxSize {
				staticMu.Lock()
				staticCache[fullPath] = entry
				staticMu.Unlock()
			}
		}

		w.Header().Set("Content-Type", "text/plain;charset=UTF-8")
		w.Header().Set("Content-Length", strconv.FormatInt(entry.size, 10))
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("ETag", entry.etag)
		w.Header().Set("Last-Modified", entry.lastModified)
		w.WriteHeader(http.StatusOK)
		if r.Method != http.MethodHead {
			_, _ = w.Write(entry.content)
		}
	})

	// 6. GET /cache/:key (in-process shared cache via sync.Map)
	mux.HandleFunc("/cache/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		key := strings.TrimPrefix(r.URL.Path, "/cache/")
		valAny, ok := sharedCache.Load(key)
		var val string
		if !ok {
			val = "cached:" + key + ":v1"
			actual, _ := sharedCache.LoadOrStore(key, val)
			val = actual.(string)
		} else {
			val = valAny.(string)
		}
		b, err := json.Marshal(cacheResponse{Key: key, Value: val, Shared: true})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json;charset=UTF-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(b)
	})

	// 7. GET /keydb/:key
	mux.HandleFunc("/keydb/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		if kdb == nil {
			w.Header().Set("Content-Type", "application/json;charset=UTF-8")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"MOJO_KEYDB_PORT not configured"}`))
			return
		}
		key := strings.TrimPrefix(r.URL.Path, "/keydb/")
		count, val, err := kdb.incrAndGet(key)
		if err != nil {
			// Single retry on stale pooled connection
			count, val, err = kdb.incrAndGet(key)
			if err != nil {
				w.Header().Set("Content-Type", "application/json;charset=UTF-8")
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(fmt.Sprintf(`{"error":%q}`, err.Error())))
				return
			}
		}
		b, err := json.Marshal(keydbResponse{Key: key, Value: val, Count: count, XS: false})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json;charset=UTF-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(b)
	})

	srv := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", port),
		Handler: mux,
	}

	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}

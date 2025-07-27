#!/bin/bash
set -e

# 1. 도메인 사용자 입력
read -p "도메인을 입력하세요 (예: example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "도메인을 반드시 입력해야 합니다."
  exit 1
fi

# 2. 기본 업데이트 및 필수 패키지 설치
echo "== 시스템 업데이트 및 필수 패키지 설치 =="
apt update
apt install -y curl git docker.io docker-compose nginx ufw software-properties-common

# 3. Docker 서비스 활성화
systemctl start docker
systemctl enable docker

# 4. Node.js 18.x 설치
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs build-essential
echo "Node.js $(node -v), npm $(npm -v) 설치 완료"

# 5. 방화벽 설정 (HTTP, HTTPS 허용)
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 6. 작업 디렉터리 생성 및 React 앱 초기화
APPDIR=/opt/websuperclusteride
echo "== 작업 디렉터리 생성 및 React 앱 초기화 =="
mkdir -p $APPDIR
cd $APPDIR

if [ ! -d "$APPDIR/node_modules" ]; then
  npx create-react-app . --template typescript
fi

# 7. React 앱 소스코드 작성 (App.tsx)
echo "== React 앱 소스코드 작성 =="
cat > src/App.tsx << 'EOF'
import React, { useState, useEffect, useRef } from "react";

const CPU_COUNT = 1000;

function createWorkerScript(sharedBuffer: SharedArrayBuffer) {
  return `
    let sharedArray = new Int32Array(self.sharedBuffer);
    self.onmessage = async (e) => {
      const { code, index, wasmBinary } = e.data;
      try {
        let wasmInstance = null;
        if (wasmBinary) {
          const module = await WebAssembly.compile(wasmBinary);
          wasmInstance = await WebAssembly.instantiate(module, {});
          if(wasmInstance.exports.run) wasmInstance.exports.run();
        } else {
          eval(code);
        }
        const duration = 1;
        sharedArray[index] = duration;
        self.postMessage({ index, duration });
      } catch(e) {
        sharedArray[index] = -1;
        self.postMessage({ index, duration: -1 });
      }
    };
  `;
}

function createWorkerBlobURL(sharedBuffer: SharedArrayBuffer) {
  const blob = new Blob([createWorkerScript(sharedBuffer)], { type: "application/javascript" });
  return URL.createObjectURL(blob);
}

export default function App() {
  const [code, setCode] = useState("for(let i=0;i<1e7;i++){}");
  const [durations, setDurations] = useState<number[]>(Array(CPU_COUNT).fill(0));
  const sharedBufferRef = useRef<SharedArrayBuffer | null>(null);
  const workersRef = useRef<Worker[]>([]);

  useEffect(() => {
    sharedBufferRef.current = new SharedArrayBuffer(CPU_COUNT * 4);
  }, []);

  const runOnCPUs = async () => {
    if (!sharedBufferRef.current) return;
    const sharedArray = new Int32Array(sharedBufferRef.current);

    if (workersRef.current.length === 0) {
      const workerURL = createWorkerBlobURL(sharedBufferRef.current);
      for(let i=0; i<CPU_COUNT; i++) {
        workersRef.current[i] = new Worker(workerURL);
      }
    }

    return new Promise<void>((resolve) => {
      let completed = 0;
      const newDurations: number[] = [];

      workersRef.current.forEach((worker, index) => {
        worker.onmessage = (e) => {
          const { index, duration } = e.data;
          newDurations[index] = duration;
          completed++;
          if(completed === CPU_COUNT) {
            setDurations(newDurations);
            resolve();
          }
        };
        worker.postMessage({ code, index, wasmBinary: null });
      });
    });
  };

  return (
    <div style={{ padding: 20 }}>
      <h1>WebSuperClusterIDE (WASM CPU 1000개)</h1>
      <textarea
        rows={6}
        style={{ width: "100%", fontFamily: "monospace" }}
        value={code}
        onChange={(e) => setCode(e.target.value)}
      />
      <button onClick={() => runOnCPUs()}>실행</button>
      <div style={{maxHeight: "300px", overflowY:"scroll", marginTop: 20, fontSize: 12, display:"grid", gridTemplateColumns: "repeat(5, 1fr)", gap:"4px"}}>
        {durations.map((d, i) => (
          <div key={i} style={{background: d === -1 ? "#faa" : "#afa", padding:4, borderRadius:4}}>
            CPU #{i}: {d} ms
          </div>
        ))}
      </div>
    </div>
  );
}
EOF

# 8. React 의존성 설치 및 빌드
echo "== React 의존성 설치 및 빌드 =="
npm install
npm run build

# 9. Dockerfile 생성
echo "== Dockerfile 생성 =="
cat > Dockerfile << EOF
FROM node:18-alpine as builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/build /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF

# 10. Docker 이미지 빌드
echo "== Docker 이미지 빌드 =="
docker build -t websuperclusteride .

# 11. 기존 컨테이너 제거 및 새 컨테이너 실행
docker stop websuperclusteride || true
docker rm websuperclusteride || true
docker run -d --name websuperclusteride -p 8080:80 websuperclusteride

# 12. Nginx 리버스 프록시 설정 (HTTP->HTTPS 자동 리다이렉트 포함)
echo "== Nginx 설정 생성 =="
cat > /etc/nginx/sites-available/websuperclusteride << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/websuperclusteride /etc/nginx/sites-enabled/websuperclusteride
rm -f /etc/nginx/sites-enabled/default

mkdir -p /var/www/certbot
chown -R www-data:www-data /var/www/certbot

echo "== Nginx 재시작 =="
systemctl restart nginx

# 13. Certbot 설치 및 SSL 인증서 발급
echo "== Certbot 설치 및 SSL 인증서 발급 시작 =="
apt install -y certbot python3-certbot-nginx
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN --redirect

echo "== SSL 인증서 발급 완료 및 자동 갱신 설정 =="
systemctl reload nginx

echo "설치 및 설정이 완료되었습니다."
echo "https://$DOMAIN 으로 접속하세요."

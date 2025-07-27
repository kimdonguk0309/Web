#!/bin/bash
set -e

# 1. Node.js 설치 (Ubuntu 예제, 필요시 수정)
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 설치 중..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  sudo apt-get install -y nodejs
else
  echo "Node.js 이미 설치됨: $(node -v)"
fi

# 2. Yarn 또는 npm 최신버전 설치
if ! command -v npm >/dev/null 2>&1; then
  echo "npm 설치 필요"
  exit 1
fi

# 3. 프로젝트 폴더 생성
PROJECT_DIR=websuperclusteride
FRONTEND_DIR=$PROJECT_DIR/frontend

if [ ! -d "$PROJECT_DIR" ]; then
  mkdir $PROJECT_DIR
fi

cd $PROJECT_DIR

# 4. Vite React TS 프로젝트 생성
if [ ! -d "$FRONTEND_DIR" ]; then
  echo "React + TS Vite 프로젝트 생성 중..."
  npm create vite@latest frontend -- --template react-ts
fi

cd frontend

# 5. Tailwind CSS, PostCSS, Autoprefixer 설치 및 설정
npm install -D tailwindcss postcss autoprefixer
npx tailwindcss init -p

# tailwind.config.js 자동 작성
cat > tailwind.config.js <<EOF
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./index.html",
    "./src/**/*.{ts,tsx}",
    "./node_modules/@shadcn/ui/**/*.{ts,tsx}"
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
EOF

# index.css 작성
mkdir -p src
cat > src/index.css <<EOF
@tailwind base;
@tailwind components;
@tailwind utilities;
EOF

# 6. shadcn/ui 및 기타 deps 설치
npm install @shadcn/ui react react-dom
npm install -D typescript @vitejs/plugin-react vite postcss autoprefixer

# 7. Vite config 작성
cat > vite.config.ts <<EOF
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()]
})
EOF

# 8. 기본 React 앱 코드 작성 (src/App.tsx, src/main.tsx)
cat > src/App.tsx <<EOF
import React, { useState, useEffect, useRef } from "react";
import { Button } from "@shadcn/ui/button";
import { Textarea } from "@shadcn/ui/textarea";

const CPU_COUNT = 1000;

function createWorkerScript() {
  return \`
    self.onmessage = (e) => {
      const { code, index } = e.data;
      let duration = -1;
      try {
        const start = performance.now();
        eval(code);
        duration = performance.now() - start;
      } catch {
        duration = -1;
      }
      self.postMessage({ index, duration });
    };
  \`;
}

function createWorkerBlobURL() {
  const blob = new Blob([createWorkerScript()], { type: "application/javascript" });
  return URL.createObjectURL(blob);
}

export default function App() {
  const [code, setCode] = useState(\`for(let i=0;i<1e7;i++) {}\`);
  const [results, setResults] = useState<number[]>(Array(CPU_COUNT).fill(0));
  const workersRef = useRef<Worker[]>([]);

  useEffect(() => {
    const url = createWorkerBlobURL();
    for(let i=0; i<CPU_COUNT; i++) {
      workersRef.current[i] = new Worker(url);
    }
    return () => {
      workersRef.current.forEach(w => w.terminate());
      URL.revokeObjectURL(url);
    };
  }, []);

  const runAllWorkers = () => {
    return new Promise<void>((resolve) => {
      let completed = 0;
      const tempResults = Array(CPU_COUNT).fill(0);

      workersRef.current.forEach((worker, idx) => {
        worker.onmessage = (e) => {
          const { index, duration } = e.data;
          tempResults[index] = duration;
          completed++;
          if (completed === CPU_COUNT) {
            setResults(tempResults);
            resolve();
          }
        };
        worker.postMessage({ code, index: idx });
      });
    });
  };

  return (
    <main className="max-w-7xl mx-auto p-4">
      <h1 className="text-3xl font-bold mb-6">WebSuperCluster 000 CPUs Benchmark</h1>

      <Textarea
        className="mb-4 font-mono text-sm h-32"
        value={code}
        onChange={e => setCode(e.target.value)}
      />

      <Button className="mb-6" onClick={() => runAllWorkers()}>
        실행
      </Button>

      <section className="grid grid-cols-5 gap-2 max-h-[400px] overflow-y-auto">
        {results.map((d, i) => (
          <div
            key={i}
            className={\`p-2 rounded text-xs font-mono \${
              d === -1 ? "bg-red-200 text-red-800" : "bg-green-100 text-green-800"
            }\`}
          >
            CPU #{i}: {d === -1 ? "에러" : d.toFixed(2) + " ms"}
          </div>
        ))}
      </section>
    </main>
  );
}
EOF

cat > src/main.tsx <<EOF
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
EOF

# 9. public/index.html 작성
mkdir -p public
cat > public/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>WebSuperCluster IDE</title>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/src/main.tsx"></script>
</body>
</html>
EOF

# 10. React 앱 빌드
npm run build

cd ..

# 11. Nginx 설치 및 설정
if ! command -v nginx >/dev/null 2>&1; then
  echo "nginx 설치 중..."
  sudo apt update
  sudo apt install -y nginx
fi

sudo mkdir -p /var/www/websuperclusteride
sudo cp -r frontend/dist/* /var/www/websuperclusteride/

# nginx 기본 설정 백업
if [ ! -f /etc/nginx/nginx.conf.bak ]; then
  sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
fi

# nginx 사이트 설정 생성
NGINX_CONF="/etc/nginx/sites-available/websuperclusteride"
sudo tee $NGINX_CONF > /dev/null <<EOF
server {
  listen 80;
  server_name _;

  root /var/www/websuperclusteride;
  index index.html;

  location / {
    try_files \$uri /index.html;
  }
}
EOF

# 심볼릭 링크 생성
if [ ! -f /etc/nginx/sites-enabled/websuperclusteride ]; then
  sudo ln -s $NGINX_CONF /etc/nginx/sites-enabled/
fi

# 기본 사이트 비활성화
if [ -f /etc/nginx/sites-enabled/default ]; then
  sudo rm /etc/nginx/sites-enabled/default
fi

# nginx 문법 체크 및 재시작
sudo nginx -t
sudo systemctl restart nginx

echo "설치 및 배포 완료!"
echo "브라우저에서 http://localhost 또는 서버IP 접속하세요."

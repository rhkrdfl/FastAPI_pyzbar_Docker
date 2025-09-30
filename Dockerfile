# 使用指定版本的Alpine Linux作为基础镜像
FROM python:3.11-alpine

# 设置工作目录
WORKDIR /app

# 配置国内镜像源并安装编译依赖
RUN echo 'http://mirrors.aliyun.com/alpine/v3.22/main' > /etc/apk/repositories && \
    echo 'http://mirrors.aliyun.com/alpine/v3.22/community' >> /etc/apk/repositories && \
    apk add --no-cache \
        gcc \
        musl-dev \
        linux-headers \
        zbar-dev \
        jpeg-dev \
        zlib-dev \
        freetype-dev \
        lcms2-dev \
        openjpeg-dev \
        tcl-dev \
        tk-dev \
        tiff-dev \
        harfbuzz-dev \
        fribidi-dev \
        libimagequant-dev

# 创建虚拟环境
RUN python -m venv /opt/venv

# 激活虚拟环境并将其添加到 PATH
ENV PATH="/opt/venv/bin:$PATH"
RUN echo 'fastapi==0.110.0' > /app/requirements.txt && \
    echo 'uvicorn[standard]==0.29.0' >> /app/requirements.txt && \
    echo 'pyzbar==0.1.8' >> /app/requirements.txt && \
    echo 'Pillow==10.2.0' >> /app/requirements.txt && \
    echo 'python-multipart==0.0.9' >> /app/requirements.txt && \
source /opt/venv/bin/activate && \
pip install -i https://mirrors.aliyun.com/pypi/simple/ --upgrade pip && \
pip install -i https://mirrors.aliyun.com/pypi/simple/ --no-cache-dir -r /app/requirements.txt
# 安装 Python 依赖
# 依赖列表基本不变，因为 base64 和 json 是标准库，fastapi 已包含
# 但为了使用 JSONResponse，确保 fastapi 版本兼容，这里保持或更新到稳定版本
# uvicorn[standard] 也保持或更新
RUN cat <<'EOF' > /app/app.py
from fastapi import FastAPI, File, UploadFile, HTTPException, Request
from fastapi.responses import JSONResponse, HTMLResponse
from pyzbar import pyzbar
from PIL import Image
import io
import base64

app = FastAPI(
    title="二维码识别服务",
    description="通过 HTTP 上传图片或 Base64 字符串，返回识别出的二维码内容",
    version="1.0.0"
)

def decode_qr_from_image(image: Image.Image):
    """从 PIL Image 中识别二维码"""
    decoded_objects = pyzbar.decode(image)
    if not decoded_objects:
        return None
    data = decoded_objects[0].data.decode("utf-8")
    return data

# 首页：文件上传 + Base64 提交（无默认值）
@app.get("/", response_class=HTMLResponse)
async def index():
    return """
    <html>
        <head>
            <meta charset="utf-8" />
            <title>二维码识别测试</title>
            <style>
                .result {
                    color: red;
                    font-size: 18px;
                    white-space: pre-wrap; /* 保留换行 */
                    word-wrap: break-word;
                }
            </style>
        </head>
        <body>
            <h1>上传图片进行二维码识别（文件上传）</h1>
            <input type="file" id="qrFile" accept="image/*">
            <button onclick="uploadFile()">上传并识别</button>
            <p id="fileResult" class="result"></p>

            <hr>

            <h1>提交 Base64 字符串进行识别</h1>
            <textarea id="base64Input" rows="8" cols="80" placeholder="在此粘贴 Base64 编码的图片"></textarea><br/><br/>
            <button onclick="submitBase64()">提交并识别</button>
            <p id="base64Result" class="result"></p>

            <hr>

            <h1>版本 v1.0 技术联系：牛阿雷</h1>

            <script>
            async function uploadFile() {
                const fileInput = document.getElementById("qrFile");
                if (!fileInput.files.length) {
                    alert("请选择图片文件");
                    return;
                }
                const file = fileInput.files[0];
                const formData = new FormData();
                formData.append("image", file);

                try {
                    const response = await fetch("/decode/file", { method: "POST", body: formData });
                    const result = await response.json();
                    document.getElementById("fileResult").innerText = JSON.stringify(result, null, 2);
                } catch (err) {
                    console.error("请求出错:", err);
                    document.getElementById("fileResult").innerText = "请求出错: " + err;
                }
            }

            async function submitBase64() {
                const base64Str = document.getElementById("base64Input").value.trim();
                if (!base64Str) {
                    alert("请输入 Base64 字符串");
                    return;
                }

                try {
                    const response = await fetch("/decode/base64", {
                        method: "POST",
                        headers: {"Content-Type": "application/json"},
                        body: JSON.stringify({image: base64Str})
                    });
                    const result = await response.json();
                    document.getElementById("base64Result").innerText = JSON.stringify(result, null, 2);
                } catch (err) {
                    console.error("请求出错:", err);
                    document.getElementById("base64Result").innerText = "请求出错: " + err;
                }
            }
            </script>
        </body>
    </html>
    """

@app.post("/decode/file")
async def decode_qr_from_file(image: UploadFile = File(...)):
    """上传图片文件识别二维码"""
    if not image.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="仅支持图片格式")

    try:
        contents = await image.read()
        pil_image = Image.open(io.BytesIO(contents)).convert("RGB")
        data = decode_qr_from_image(pil_image)
        return {
            "success": True,
            "data": data,
            "message": "识别成功" if data else "未检测到二维码"
        }
    except Exception as e:
        return JSONResponse(status_code=500, content={"detail": f"处理失败: {str(e)}"})

@app.post("/decode/base64")
async def decode_qr_from_base64(request: Request):
    """
    支持：
      - JSON 提交：Content-Type: application/json， body: {"image": "<base64>"}
      - 表单提交：application/x-www-form-urlencoded 或 multipart/form-data（name=image）
      - data URI (data:image/png;base64,....)
    """
    image_b64 = None
    ct = request.headers.get("content-type", "")
    try:
        if "application/json" in ct:
            body = await request.json()
            if isinstance(body, dict):
                image_b64 = body.get("image")
        else:
            form = await request.form()
            image_b64 = form.get("image")
    except Exception:
        image_b64 = None

    if not image_b64:
        raise HTTPException(status_code=400, detail="缺少 image 字段（支持 JSON 或表单提交）")

    # 如果是 data URI，去掉前缀
    if isinstance(image_b64, str) and image_b64.startswith("data:"):
        try:
            _, image_b64 = image_b64.split(",", 1)
        except Exception:
            return JSONResponse(status_code=400, content={"detail": "无效的 data URI 格式"})

    # Base64 解码
    try:
        image_data = base64.b64decode(image_b64)
    except Exception as e:
        return JSONResponse(status_code=400, content={"detail": f"Base64 解码失败: {str(e)}"})

    # 打开图片并识别
    try:
        pil_image = Image.open(io.BytesIO(image_data)).convert("RGB")
        data = decode_qr_from_image(pil_image)
        return {
            "success": True,
            "data": data,
            "message": "识别成功" if data else "未检测到二维码"
        }
    except Exception as e:
        return JSONResponse(status_code=500, content={"detail": f"识别失败: {str(e)}"})

@app.get("/health")
async def health_check():
    return {"状态": "正常", "服务": "二维码识别服务"}
EOF


# 生成启动脚本
RUN cat <<'EOF' > /app.sh
#!/bin/sh
set -e

if [ -n "$CMD_ENV" ] ; then
    exec $CMD_ENV
else
    cd /app
    source /opt/venv/bin/activate
    exec uvicorn app:app --host 0.0.0.0 --port 80
fi
EOF

RUN chmod +x /app.sh

# 暴露端口
EXPOSE 80

# 设置环境变量
ENV CMD_ENV=""

# 指定容器启动时运行的命令
ENTRYPOINT ["/app.sh"]

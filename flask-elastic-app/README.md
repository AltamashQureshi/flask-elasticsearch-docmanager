# Flask Elasticsearch Document Manager

A full-featured document management system with CRUD operations, search functionality, and Elasticsearch backend.

## Features

- ✅ User Authentication
- ✅ Upload **ANY file type** (text, images, PDFs, documents, archives, etc.)
- ✅ Full-text search across text files
- ✅ Download any uploaded file
- ✅ View document details
- ✅ Edit text file content (binary files can be downloaded and re-uploaded)
- ✅ Delete documents
- ✅ Auto-detection of text vs binary files
- ✅ Responsive UI with modern design
- ✅ Elasticsearch for fast search and storage

## Supported File Types

### Text Files (Searchable & Editable)
- .txt, .log, .json, .xml, .csv, .md
- .py, .js, .html, .css, .java, .cpp, .c, .h
- .sh, .yml, .yaml, .ini, .conf, .sql
- .php, .rb, .go, .rs, .swift, .kt
- Any UTF-8 encoded text file

### Binary Files (Upload & Download)
- Images: .jpg, .png, .gif, .bmp, .svg, .webp
- Documents: .pdf, .docx, .xlsx, .pptx
- Archives: .zip, .tar, .gz, .rar
- Media: .mp3, .mp4, .avi, .mov
- Executables: .exe, .bin, .dll
- Any other file type

## Quick Start

```bash
chmod +x setup.sh
./setup.sh
```

## Access

- URL: http://localhost
- Username: admin
- Password: admin

## How It Works

1. **Text Files**: Stored as searchable text in Elasticsearch
   - Content is indexed and searchable
   - Can be edited directly in the browser
   
2. **Binary Files**: Stored as base64-encoded data
   - Not searchable by content (filename is searchable)
   - Can be downloaded in original format
   - Edit by downloading and re-uploading

## API Endpoints

- GET /api/stats - Get document statistics

## Tech Stack

- Flask (Python web framework)
- Elasticsearch 8.11.0 (Search and storage)
- Nginx (Reverse proxy)
- Docker (Containerization)

## Management

### Stop all containers
```bash
docker stop elasticsearch flask nginx
```

### Start all containers
```bash
docker start elasticsearch flask nginx
```

### View logs
```bash
docker logs flask
docker logs elasticsearch
docker logs nginx
```

### Remove everything
```bash
docker rm -f elasticsearch flask nginx
docker network rm flasknet
docker rmi flask-app
```

## File Size Limits

- Nginx: 10MB max file size (configurable in nginx/default.conf)
- Elasticsearch: Can handle large files via base64 encoding
- Recommended: Keep files under 10MB for optimal performance

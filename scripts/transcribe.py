#!/usr/bin/env python3
"""Transcribe audio using Gemini Flash. Usage: python3 transcribe.py <audio_path>"""
import sys, os, subprocess, tempfile

def transcribe(audio_path):
    if not os.path.exists(audio_path):
        print(f"Error: file not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    ext = os.path.splitext(audio_path)[1].lower()
    tmp_path = None
    if ext in ('.ogg', '.oga', '.opus'):
        tmp_fd, tmp_path = tempfile.mkstemp(suffix='.mp3')
        os.close(tmp_fd)
        result = subprocess.run(['ffmpeg', '-y', '-i', audio_path, '-q:a', '2', tmp_path], capture_output=True)
        if result.returncode != 0:
            print(f"Error: ffmpeg failed: {result.stderr.decode()}", file=sys.stderr)
            os.unlink(tmp_path)
            sys.exit(1)
        upload_path = tmp_path
    else:
        upload_path = audio_path

    try:
        import google.generativeai as genai

        api_key = os.environ.get('GEMINI_API_KEY', '')
        if not api_key:
            env_path = '/opt/second-brain/.env'
            if os.path.exists(env_path):
                with open(env_path, encoding='utf-8') as f:
                    for line in f:
                        if line.startswith('GEMINI_API_KEY='):
                            api_key = line.strip().split('=', 1)[1].strip('"\'')
                            break
        if not api_key:
            print('Error: GEMINI_API_KEY not found', file=sys.stderr)
            sys.exit(1)

        genai.configure(api_key=api_key)
        model = genai.GenerativeModel('gemini-2.0-flash')
        audio_file = genai.upload_file(upload_path)
        response = model.generate_content([
            'Транскрибируй это аудио. Верни ТОЛЬКО текст, без пояснений. Если язык русский — пиши на русском.',
            audio_file
        ])
        print(response.text)
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python3 transcribe.py <audio_path>')
        sys.exit(1)
    transcribe(sys.argv[1])

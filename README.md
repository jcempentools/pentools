# Create an Hybrid UEFI GPT + BIOS GPT/MBR boot USB disk | Slivermetal'S BLOG

Using Ventoy APP

## Remover TPM e apps 

Adicionar o arquivo ```autounattend.xml``` ao diretório raiz do conteúdo .iso, que está localizado na pasta ```/boot/ISOs/windows```.

- Gerar o arquivo: https://schneegans.de/windows/unattend-generator/
- Tutorial: https://www.youtube.com/watch?v=DMA4J9I4nS8

Use ```.\sync.ps1 E:``` por exemplo, para que a unidade 'e:' fique com o mesmo conteudo do atual diretório.

# Origem

- https://github.com/jcempentools/pentools.git
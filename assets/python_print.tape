Set Margin 20
Set MarginFill "#6B50FF"
Set Width 1024
Set Height 768
Output python_print.gif


Type@50ms "python"
Enter
Sleep 1s

Type@50ms "import zignal"
Enter
Sleep 1s

Type@50ms "image = zignal.Image.load('liza.jpg')"
Enter
Sleep 1s

Type@50ms "print(f'{image.resize((75,75)):braille}')"
Enter
Sleep 3s
# Java Test Snippets

## Phase 1: File I/O

### Create a File

**Main.java** (no workspace files needed)
```java
import java.io.FileWriter;
import java.io.IOException;

public class Main {
    public static void main(String[] args) throws IOException {
        FileWriter fw = new FileWriter("hello.txt");
        fw.write("Hello from Piston!\nLine 2\nLine 3");
        fw.close();
        System.out.println("File created: hello.txt");
    }
}
```

---

### Read a File

**Main.java** (no workspace files needed)
```java
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;

public class Main {
    public static void main(String[] args) throws IOException {
        BufferedReader br = new BufferedReader(new FileReader("hello.txt"));
        String line;
        while ((line = br.readLine()) != null) {
            System.out.println(line);
        }
        br.close();
    }
}
```

> Note: To test read, first run the create snippet so `hello.txt` exists in the sandbox — but remember the sandbox is destroyed after each run. To read a file you wrote, do both write + read in the same program, or use workspace files.

### Write + Read in One Run

```java
import java.io.*;

public class Main {
    public static void main(String[] args) throws IOException {
        // Write
        FileWriter fw = new FileWriter("hello.txt");
        fw.write("Hello from Piston!\nLine 2\nLine 3");
        fw.close();

        // Read back
        BufferedReader br = new BufferedReader(new FileReader("hello.txt"));
        String line;
        while ((line = br.readLine()) != null) {
            System.out.println(line);
        }
        br.close();
    }
}
```

---

## Phase 2: OOP Concepts

### Concept 1 — Inheritance + Method Overriding

Save `Animal.java` to workspace, run `Main.java`.

**Animal.java** (workspace)
```java
public class Animal {
    String name;

    public Animal(String name) {
        this.name = name;
    }

    public String speak() {
        return name + " makes a sound.";
    }
}
```

**Main.java**
```java
public class Main extends Animal {
    public Main(String name) {
        super(name);
    }

    @Override
    public String speak() {
        return name + " says: Woof!";
    }

    public static void main(String[] args) {
        Animal a = new Animal("Cat");
        Animal d = new Main("Dog");

        System.out.println(a.speak());
        System.out.println(d.speak());
    }
}
```

Expected output:
```
Cat makes a sound.
Dog says: Woof!
```

---

### Concept 2 — Interface + Polymorphism

Save `Shape.java` to workspace, run `Main.java`.

**Shape.java** (workspace)
```java
public interface Shape {
    double area();
    default String describe() {
        return "I am a shape with area: " + area();
    }
}

class Circle implements Shape {
    double radius;
    Circle(double r) { this.radius = r; }
    public double area() { return Math.PI * radius * radius; }
}

class Rectangle implements Shape {
    double w, h;
    Rectangle(double w, double h) { this.w = w; this.h = h; }
    public double area() { return w * h; }
}
```

**Main.java**
```java
public class Main {
    public static void main(String[] args) {
        Shape[] shapes = { new Circle(5), new Rectangle(4, 6) };
        for (Shape s : shapes) {
            System.out.printf("%.2f - %s%n", s.area(), s.describe());
        }
    }
}
```

Expected output:
```
78.54 — I am a shape with area: 78.53981633974483
24.00 — I am a shape with area: 24.0
```

---

### Concept 3 — Encapsulation + Static Members

**Main.java** (no workspace needed)
```java
public class Main {
    static int count = 0;

    private String name;
    private int id;

    public Main(String name) {
        this.name = name;
        this.id = ++count;
    }

    public String getName() { return name; }
    public int getId() { return id; }

    public static void main(String[] args) {
        Main a = new Main("Alice");
        Main b = new Main("Bob");
        Main c = new Main("Charlie");

        System.out.println("Total created: " + count);
        for (Main m : new Main[]{a, b, c}) {
            System.out.println("ID " + m.getId() + ": " + m.getName());
        }
    }
}
```

Expected output:
```
Total created: 3
ID 1: Alice
ID 2: Bob
ID 3: Charlie
```

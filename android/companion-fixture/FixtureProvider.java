package dev.droidbridge.companionfixture;
import android.content.*;
import android.database.*;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.graphics.*;
import java.io.*;
public final class FixtureProvider extends ContentProvider {
    static final int SIZE=2*1024*1024;
    @Override public boolean onCreate(){return true;}
    private boolean image(Uri uri){return "sample.png".equals(uri.getLastPathSegment());}
    @Override public String getType(Uri uri){return image(uri)?"image/png":"application/octet-stream";}
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] arguments,String order){
        MatrixCursor cursor=new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE});cursor.addRow(new Object[]{uri.getLastPathSegment(),image(uri)?null:SIZE});return cursor;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException {
        if(!"r".equals(mode))throw new FileNotFoundException("read only");
        if(!java.util.Arrays.asList("sample.bin","slow.bin","sample.png").contains(uri.getLastPathSegment()))throw new FileNotFoundException("unknown fixture");
        try {
            ParcelFileDescriptor[] pipe=ParcelFileDescriptor.createReliablePipe();
            new Thread(()->{
                try(OutputStream out=new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])){
                    if(image(uri)){
                        Bitmap bitmap=Bitmap.createBitmap(128,128,Bitmap.Config.ARGB_8888);bitmap.eraseColor(Color.rgb(20,140,220));bitmap.compress(Bitmap.CompressFormat.PNG,100,out);bitmap.recycle();
                    }else{
                        byte[] chunk=new byte[65536];for(int i=0;i<chunk.length;i++)chunk[i]=(byte)(i%251);
                        for(int sent=0;sent<SIZE;sent+=chunk.length){out.write(chunk);if("slow.bin".equals(uri.getLastPathSegment()))Thread.sleep(250);}
                    }
                }catch(Exception cancelled){try{pipe[1].closeWithError("provider closed");}catch(IOException ignored){}}
            },"CompanionFixtureProvider").start();return pipe[0];
        }catch(IOException failure){throw new FileNotFoundException(failure.toString());}
    }
    @Override public Uri insert(Uri uri,ContentValues values){throw new UnsupportedOperationException();}
    @Override public int update(Uri uri,ContentValues values,String s,String[] a){throw new UnsupportedOperationException();}
    @Override public int delete(Uri uri,String s,String[] a){throw new UnsupportedOperationException();}
}
